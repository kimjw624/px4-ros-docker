#!/usr/bin/env bash
# Launch the PX4 + Gazebo + ROS 2 container with GPU, GUI, and host networking.
# NOTE: docker-compose is the primary path (docker compose up -d). This script
# is an alternative for a single throwaway container (--rm: nothing persists
# except the ws_shared mount).
set -e

IMAGE=px4-jazzy:1.16
CONTAINER=px4sitl

# Allow the container to draw on your X display (run once per login is enough).
xhost +local:docker >/dev/null 2>&1 || true

docker run -it --rm \
    --name ${CONTAINER} \
    --network host \
    --ipc host \
    --gpus all \
    --runtime nvidia \
    -e DISPLAY=${DISPLAY} \
    -e QT_X11_NO_MITSHM=1 \
    -e NVIDIA_DRIVER_CAPABILITIES=all \
    -v /tmp/.X11-unix:/tmp/.X11-unix:rw \
    -v "$HOME/px4-ros2-docker/ws_shared":/home/dev/ws_shared:rw \
    ${IMAGE}
