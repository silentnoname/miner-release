#!/bin/bash

log_info() {
    # Blue color for informational messages
    echo -e "\033[0;34mINFO: $1\033[0m" >&2
}

log_warning() {
    # Yellow color for warning messages, printed to stderr
    echo -e "\033[0;33mWARNING: $1\033[0m" >&2
}

log_error() {
    # Red color for error messages, printed to stderr
    echo -e "\033[0;31mERROR: $1\033[0m" >&2
}



# Validate internet connectivity to essential services
validate_connectivity() {
    # List of essential URLs to check connectivity
    local urls=("https://huggingface.co")

    for url in "${urls[@]}"; do
        if ! wget --spider -q "$url"; then
            log_error "Unable to connect to $url. Check your internet connection or access to the site."
            exit 1
        else
            log_info "Connectivity to $url verified."
        fi
    done
}


setup_conda_environment() {
    log_info "Updating package lists..."
    sudo apt-get update -qq >/dev/null 2>&1

    if [ -d "$HOME/miniconda" ]; then
        log_info "Miniconda already installed at $HOME/miniconda. Proceed to create a conda environment."
    else
        log_info "Installing Miniconda..."
        wget --quiet --show-progress --progress=bar:force:noscroll https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O ~/miniconda.sh
        bash ~/miniconda.sh -b -p $HOME/miniconda
        export PATH="$HOME/miniconda/bin:$PATH"
        rm ~/miniconda.sh
    fi

    # Ensure Conda is correctly initialized
    source ~/miniconda/bin/activate
    ~/miniconda/bin/conda init bash >/dev/null 2>&1

    # Source .bashrc to update the path for conda, if it exists
    if [ -f "$HOME/.bashrc" ]; then
        log_info "Sourcing .bashrc to update the path for conda"
        source "$HOME/.bashrc"
    elif [ -f "$HOME/.bash_profile" ]; then
        # Fallback for systems that use .bash_profile instead of .bashrc
        log_info "Sourcing .bash_profile to update the path for conda"
        source "$HOME/.bash_profile"
    else
        log_error "Could not find a .bashrc or .bash_profile file to source."
    fi

    # Check if the Conda environment already exists
    if conda info --envs | grep 'llm-venv' > /dev/null; then
        log_info "Conda environment 'llm-venv' already exists. Skipping creation."
    else
        log_info "Creating a virtual environment with Miniconda..."
        # Suppressing the output completely, consider logging at least errors
        conda create -n llm-venv python=3.11 -y --quiet >/dev/null 2>&1
        log_info "Conda virtual environment 'llm-venv' created."
    fi

    conda activate llm-venv
    log_info "Conda virtual environment 'llm-venv' activated."
}


# Retrieve model size, quantization and name information
fetchModelDetails() {
    local heurist_model_id="$1"
    log_info "Fetching model details for $heurist_model_id..."

    local models_json=$(curl -s https://raw.githubusercontent.com/heurist-network/heurist-models/main/models.json)
    if [ -z "$models_json" ]; then
        log_error "Failed to fetch model details from $models_json_url"
        exit 1
    fi

    local model_found=$(echo "$models_json" | jq -r --arg heurist_model_id "$heurist_model_id" '.[] | select(.name == $heurist_model_id)')
    if [ -z "$model_found" ]; then
        log_error "Heurist Model ID '$heurist_model_id' not found in models.json."
        exit 1
    fi

    # Extracting necessary details
    local size_gb=$(echo "$model_found" | jq -r '.size_gb')
    local quantization=$(echo "$model_found" | jq -r '.type' | grep -q '16b' && echo "None" || echo "gptq")
    local hf_model_id=$(echo "$model_found" | jq -r '.hf_id')
    local revision=$(echo "$model_found" | jq -r '.hf_branch // "None"')

    log_info "Model details: HF_ID=$hf_model_id, Size_GB=$size_gb, Quantization=$quantization, Revision=$revision"
    # Echoing the details for capture by the caller
    echo "$size_gb $quantization $hf_model_id $revision"
}

# Validate GPU VRAM is enough to host expected model
validateVram() {
    local size_gb="$1"
    # Assuming the size_gb is the required VRAM in GB, convert it to MB
    local required_mb=$(echo "$size_gb*1024" | bc)

    log_info "Validating available VRAM against model requirements..."

    # Check if nvidia-smi is available
    if ! command -v nvidia-smi &> /dev/null; then
        log_error "nvidia-smi tool not found. Unable to check available VRAM."
        exit 1
    fi

    # Fetch the available VRAM in MB
    local available_mb=$(nvidia-smi --query-gpu=memory.free --format=csv,noheader,nounits | awk -v gpu_id="$gpu_ids" 'NR==gpu_id+1{print $1}')

    if [ -z "$available_mb" ]; then
        log_error "Failed to fetch available VRAM."
        exit 1
    fi

    log_info "Available VRAM: ${available_mb}MB, Required VRAM: ${required_mb}MB"

    # Compare available and required VRAM
    if [ "$available_mb" -lt "$required_mb" ]; then
        log_error "Insufficient VRAM. Available: ${available_mb}MB, Required: ${required_mb}MB."
        exit 1
    else
        log_info "Sufficient VRAM available. Proceeding..."
    fi

    # Determine GPU memory utilization based on model name and available VRAM
    if [[ "$heurist_model_id" == *"mixtral-8x7b-gptq"* ]] && [ "$available_mb" -gt 32000 ]; then
        local gpu_memory_util=$(echo "scale=2; (32000-1000)/$available_mb" | bc)
    elif [[ "$heurist_model_id" == *"yi-34b-gptq"* ]] && [ "$available_mb" -gt 40000 ]; then
        local gpu_memory_util=$(echo "scale=2; (40000-1000)/$available_mb" | bc)
    elif [[ "$heurist_model_id" == *"70b"* ]] && [ "$available_mb" -gt 44000 ]; then
        local gpu_memory_util=$(echo "scale=2; (44000-1000)/$available_mb" | bc)
    elif [[ "$heurist_model_id" == *"8b"* ]] && [ "$available_mb" -gt 19000 ]; then
        local gpu_memory_util=$(echo "scale=2; (19000-1000)/$available_mb" | bc)
    elif [[ "$heurist_model_id" == *"pro-mistral-7b"* ]] && [ "$available_mb" -gt 18000 ]; then
        local gpu_memory_util=$(echo "scale=2; (18000-1000)/$available_mb" | bc)
    else
        local gpu_memory_util=$(echo "scale=2; (12000-1000)/$available_mb" | bc) # Default value or handle other cases as needed
    fi

    # Output the gpu_memory_util value
    printf "%.2f" "$gpu_memory_util"
}

getModelId() {
    local heurist_model_id="$1"

    # If no model ID was provided, exit with an error message
    if [ -z "$heurist_model_id" ]; then
        log_error "No model ID provided. Please provide a model ID. See https://docs.heurist.ai/integration/supported-models for supported models."
        exit 1
    fi
    # Return the determined model ID
    echo "$heurist_model_id"
}

main() {
    log_info "Starting script execution..."
    validate_connectivity
    setup_conda_environment

    # Default values for the new arguments
    local miner_id_index=0
    local port=8000
    local gpu_ids="0" # User can specify GPUs to use. Example: "0,1" for GPUs 0 and 1.

    # Fetch model details including the model ID, required VRAM size, quantization method, and model name
    heurist_model_id=$(getModelId "$1") || exit 1
    read -r size_gb quantization hf_model_id revision < <(fetchModelDetails "$heurist_model_id")

    shift 1
    # Parse additional arguments
    while (( "$#" )); do
        case "$1" in
            --miner-id-index)
                miner_id_index=$2
                shift 2
                ;;
            --port)
                port=$2
                shift 2
                ;;
            --gpu-ids)
                gpu_ids=$2
                shift 2
                ;;
            *) # unrecognized argument
                break
                ;;
        esac
    done

    # Check if the model details were not properly fetched
    if [ -z "$size_gb" ] || [ -z "$quantization" ] || [ -z "$hf_model_id" ] || [ -z "$revision" ]; then
        log_error "Failed to fetch model details. Exiting."
        exit 1
    fi

    # Validate if the system has enough VRAM for the model
    gpu_memory_util=$(validateVram "$size_gb")
    log_info "GPU Memory Utilization ratio for vllm: $gpu_memory_util"

    # Assuming all validations passed, proceed to execute the Python script with the model details
    log_info "Executing Python script with Heurist model ID: $heurist_model_id, Quantization: $quantization, HuggingFace model ID: $hf_model_id, Revision: $revision, Miner ID Index: $miner_id_index, Port: $port, GPU IDs: $gpu_ids"
    local python_script=$(ls llm-miner-*.py | head -n 1)
    if [[ -n "$python_script" ]]; then
        python "$python_script" "$hf_model_id" "$quantization" "$heurist_model_id" $gpu_memory_util "$revision" "$miner_id_index" "$port" "$gpu_ids"
        log_info "Python script executed successfully."
    else
        log_error "No Python script matching 'llm-miner-*.py' found."
        exit 1
    fi

    log_info "Script execution completed."
}

main "$@"
