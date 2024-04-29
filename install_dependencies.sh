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

# Function to check command prerequisites and report all missing dependencies
check_prerequisites() {
    local missing_prerequisites=()
    # Base prerequisites without considering Python venv yet
    local prerequisites=("jq" "wget" "bc")

    # Determine the default Python version
    local python_version=$(python3 --version 2>&1 | grep -oP 'Python \K[0-9]+\.[0-9]+')

    # Decide whether to check for python3-venv or python3.8-venv based on Python version
    if [[ "$python_version" =~ ^3\.(8|9|10|11)$ ]]; then
        prerequisites+=("python3-venv")
    else
        prerequisites+=("python3.8-venv")
    fi

    for prerequisite in "${prerequisites[@]}"; do
        # Handle Python venv packages separately
        if [[ "$prerequisite" == "python3-venv" || "$prerequisite" == "python3.8-venv" ]]; then
            if ! dpkg -l | grep -q "$prerequisite"; then
                missing_prerequisites+=("$prerequisite")
            fi
        # Check for the presence of other executable commands
        elif ! command -v "$prerequisite" &> /dev/null; then
            missing_prerequisites+=("$prerequisite")
        fi
    done

    if [ ${#missing_prerequisites[@]} -eq 0 ]; then
        log_info "All prerequisites are satisfied."
    else
        for missing in "${missing_prerequisites[@]}"; do
            if [[ "$missing" == "python3-venv" || "$missing" == "python3.8-venv" ]]; then
                log_error "$missing is not installed but is required. Please install $missing with the following command: sudo apt update && sudo apt upgrade && sudo apt install software-properties-common && sudo add-apt-repository ppa:deadsnakes/ppa && sudo apt install $missing"
            else
                log_error "$missing is not installed but is required. Please install $missing with the following command: sudo apt update && sudo apt install $missing"
            fi
        done
        exit 1
    fi
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
    pip config set global.index-url https://mirrors.aliyun.com/pypi/simple/
}

install_with_spinner() {
    local dep=$1
    (
        pip install "$dep" --verbose > install_log.txt 2>&1
        echo $? > /tmp/install_exit_status.tmp
    ) &

    pid=$! # PID of the pip install process
    spinner="/-\|"

    # Use printf for consistent formatting
    printf "Installing %-20s" "$dep..."

    while kill -0 $pid 2> /dev/null; do
        for i in $(seq 0 3); do
            printf "\b${spinner:i:1}"
            sleep 0.2
        done
    done

    wait $pid
    exit_status=$(cat /tmp/install_exit_status.tmp)
    rm /tmp/install_exit_status.tmp

    if [ $exit_status -eq 0 ]; then
        printf "\b Done.\n"
    else
        printf "\b Failed.\n"
        return 1
    fi
}

# Example usage for your dependency installation function
install_dependencies() {
    log_info "Installing Python dependencies..."
    local dependencies=("vllm" "python-dotenv" "toml" "openai" "triton==2.1.0" "wheel" "packaging" "psutil")

    for dep in "${dependencies[@]}"; do
        if ! install_with_spinner "$dep"; then
            log_error "Failed to install $dep."
            exit 1
        fi
    done

    log_info "All dependencies installed successfully."
}


main() {
    log_info "Starting installing ..."
    check_prerequisites
    validate_connectivity
    setup_conda_environment
    install_dependencies
    }

main "$@"
