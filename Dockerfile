# RunPod official PyTorch base: includes nginx (required for RunPod proxy),
# openssh-server, JupyterLab, Python 3.11, CUDA 12.4, and the canonical /start.sh
FROM runpod/pytorch:2.4.0-py3.11-cuda12.4.1-devel-ubuntu22.04

# Install TensorFlow (bundles its own CUDA Python wheels alongside system CUDA)
# and HuggingFace + inference server dependencies
COPY requirements.txt /tmp/requirements.txt
RUN pip install --no-cache-dir -r /tmp/requirements.txt

# Copy inference server
COPY inference/ /inference/

# Copy post-start hook: runs after SSH and JupyterLab are ready
# (start.sh in the base image calls /post_start.sh if it exists)
COPY post_start.sh /post_start.sh
RUN chmod +x /post_start.sh

# Persistent HuggingFace cache lives on the network volume at /workspace
ENV HF_HOME=/workspace/.cache/huggingface
ENV TRANSFORMERS_CACHE=/workspace/.cache/huggingface/hub

# Use CMD, not ENTRYPOINT — RunPod requires CMD to stay overridable
CMD ["/start.sh"]
