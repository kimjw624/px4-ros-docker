# PX4 v1.16 SITL + Gazebo Harmonic + ROS 2 Jazzy
# Base: OSRF ROS 2 Jazzy on Ubuntu 24.04 (Noble)
FROM osrf/ros:jazzy-desktop-full

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-c"]

# ---- Pin the versions we matched ----
ARG PX4_VERSION=v1.16.0
ARG PX4_MSGS_BRANCH=release/1.16

# ---- Base tooling ----
RUN apt-get update && apt-get install -y --no-install-recommends \
        git wget curl sudo lsb-release gnupg \
        python3-pip python3-venv \
        build-essential cmake ninja-build \
        ros-jazzy-ros-gz \
    && rm -rf /var/lib/apt/lists/*

# ---- Python 3.10 for JAX-based TRAINING (e.g. PS2-RL venv) ----
RUN apt-get update && apt-get install -y --no-install-recommends \
        software-properties-common gnupg dirmngr ca-certificates \
    && add-apt-repository ppa:deadsnakes/ppa -y \
    && apt-get update && apt-get install -y --no-install-recommends \
        python3.10 python3.10-venv python3.10-dev \
    && rm -rf /var/lib/apt/lists/*

# ---- CPU JAX + policy deps for DEPLOYMENT (system python 3.12, which has rclpy) ----
# The bridge runs here (rclpy is compiled for 3.12 and cannot load in the 3.10 venv).
# CPU build on purpose: inference is single-state, latency-bound; matches jax_platform=cpu.
RUN python3 -m pip install --break-system-packages --no-cache-dir \
        "jax==0.6.2" "jaxlib==0.6.2" \
        "numpy==1.26.4" "scipy==1.14.1" "qpax==0.0.9"

# ---- Non-root user (matches typical host UID 1000) ----
ARG USERNAME=dev
ARG UID=1000
ARG GID=1000
RUN if ! getent group ${GID} >/dev/null; then groupadd --gid ${GID} ${USERNAME}; fi \
    && if ! id -u ${UID} >/dev/null 2>&1; then \
         useradd --uid ${UID} --gid ${GID} -m ${USERNAME}; \
       else \
         existing_user=$(id -nu ${UID}); \
         if [ "${existing_user}" != "${USERNAME}" ]; then usermod -l ${USERNAME} -d /home/${USERNAME} -m ${existing_user}; fi; \
       fi \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME} \
    && chmod 0440 /etc/sudoers.d/${USERNAME}
USER ${USERNAME}

# ---- Clone + build PX4 v1.16 from source ----
# ubuntu.sh installs Gazebo Harmonic and all SITL deps automatically.
RUN git clone --recursive --branch ${PX4_VERSION} \
        https://github.com/PX4/PX4-Autopilot.git \
        /home/${USERNAME}/PX4-Autopilot
RUN cd /home/${USERNAME}/PX4-Autopilot \
    && bash ./Tools/setup/ubuntu.sh --no-nuttx
# Compile PX4 SITL WITHOUT launching it (bare cmake build target,
# so the RUN step exits instead of dropping into the pxh> shell).
RUN cd /home/${USERNAME}/PX4-Autopilot \
    && DONT_RUN=1 make px4_sitl

# ---- Micro XRCE-DDS Agent (PX4 <-> ROS 2 bridge) ----
RUN cd /home/${USERNAME} \
    && git clone -b v2.4.3 https://github.com/eProsima/Micro-XRCE-DDS-Agent.git \
    && cd Micro-XRCE-DDS-Agent \
    && mkdir build && cd build \
    && cmake .. \
    && make -j$(nproc) \
    && sudo make install \
    && sudo ldconfig /usr/local/lib/

# ---- ROS 2 workspace with px4_msgs + px4_ros_com (release/1.16) ----
RUN mkdir -p /home/${USERNAME}/ws_ros2/src \
    && cd /home/${USERNAME}/ws_ros2/src \
    && git clone -b ${PX4_MSGS_BRANCH} https://github.com/PX4/px4_msgs.git \
    && git clone -b ${PX4_MSGS_BRANCH} https://github.com/PX4/px4_ros_com.git
RUN cd /home/${USERNAME}/ws_ros2 \
    && source /opt/ros/jazzy/setup.bash \
    && colcon build

# ---- Convenience: auto-source on every shell ----
# Order matters: ROS base, then px4_msgs workspace, then (if built) the ws_shared
# deployment workspace, then PYTHONPATH so `import ps2rl` resolves. The ws_shared
# lines are guarded so a shell still works before the bridge is built.
RUN echo "source /opt/ros/jazzy/setup.bash"                                         >> /home/${USERNAME}/.bashrc \
    && echo "source /home/${USERNAME}/ws_ros2/install/setup.bash"                   >> /home/${USERNAME}/.bashrc \
    && echo "[ -f /home/${USERNAME}/ws_shared/install/setup.bash ] && source /home/${USERNAME}/ws_shared/install/setup.bash" >> /home/${USERNAME}/.bashrc \
    && echo "export PYTHONPATH=/home/${USERNAME}/ws_shared/PS2-RL:\$PYTHONPATH"      >> /home/${USERNAME}/.bashrc

WORKDIR /home/${USERNAME}
CMD ["/bin/bash"]
