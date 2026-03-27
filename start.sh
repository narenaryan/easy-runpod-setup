#!/bin/bash
# Canonical RunPod start.sh — mirrors the official RunPod container template.
# Reference: https://github.com/runpod/containers/blob/main/container-template/start.sh
#
# Execution order:
#   1. nginx  (required for RunPod HTTP proxy routing)
#   2. /pre_start.sh  (optional, not used by this image)
#   3. SSH    (when PUBLIC_KEY env var is set by RunPod)
#   4. JupyterLab  (when JUPYTER_PASSWORD env var is set)
#   5. env export  (makes all env vars available in new shell sessions)
#   6. /post_start.sh  ← inference server starts here
#   7. sleep infinity  (keeps container alive)
set -e

start_nginx() {
    echo "Starting nginx..."
    service nginx start
}

execute_script() {
    local script_path=$1
    local script_msg=$2
    if [[ -f ${script_path} ]]; then
        echo "${script_msg}"
        bash "${script_path}"
    fi
}

setup_ssh() {
    if [[ -n $PUBLIC_KEY ]]; then
        echo "Configuring SSH..."
        mkdir -p ~/.ssh
        echo "$PUBLIC_KEY" >> ~/.ssh/authorized_keys
        chmod 700 ~/.ssh
        chmod 600 ~/.ssh/authorized_keys

        for type in rsa dsa ecdsa ed25519; do
            keyfile="/etc/ssh/ssh_host_${type}_key"
            if [[ ! -f $keyfile ]]; then
                ssh-keygen -t "$type" -f "$keyfile" -q -N ''
            fi
        done

        service ssh start
        echo "SSH ready"
    fi
}

export_env_vars() {
    echo "Exporting environment variables to /etc/rp_environment..."
    printenv | grep -E '^[A-Z_][A-Z0-9_]*=' | grep -v '^PUBLIC_KEY' | \
        awk -F= '{ val=$0; sub(/^[^=]*=/,"",val); print "export " $1 "=\"" val "\"" }' \
        > /etc/rp_environment
    grep -q 'source /etc/rp_environment' ~/.bashrc || \
        echo 'source /etc/rp_environment' >> ~/.bashrc
}

start_jupyter() {
    if [[ -n $JUPYTER_PASSWORD ]]; then
        echo "Starting JupyterLab on port 8888..."
        mkdir -p /workspace
        nohup python3 -m jupyter lab \
            --allow-root \
            --no-browser \
            --port=8888 \
            --ip=* \
            --FileContentsManager.delete_to_trash=False \
            --ServerApp.terminado_settings='{"shell_command":["/bin/bash"]}' \
            --IdentityProvider.token="$JUPYTER_PASSWORD" \
            --ServerApp.allow_origin=* \
            --ServerApp.preferred_dir=/workspace \
            &>/workspace/jupyter.log &
        echo "JupyterLab started (log: /workspace/jupyter.log)"
    fi
}

start_nginx
execute_script "/pre_start.sh" "Running pre_start.sh..."

echo "Pod started"
setup_ssh
start_jupyter
export_env_vars

echo "Core services ready. Running post_start.sh..."
execute_script "/post_start.sh" "Running post_start.sh..."

echo "Pod is ready."
sleep infinity
