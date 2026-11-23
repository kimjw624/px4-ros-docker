#!/usr/bin/env bash
# Launch the PX4 + Gazebo + ROS 2 container with GPU, GUI, and host networking.
# NOTE: docker-compose is the primary path (docker compose up -d). This script
# is an alternative for a single throwaway container (--rm: nothing persists
# except the ws_shared mount).
set -e

IMAGE=px4-jazzy:1.16
CONTAINER=px4sitl
# ws_shared next to this script, whatever the clone is called (was hard-coded to
# $HOME/px4-ros2-docker, which does not match a default clone of px4-ros-docker).
WS_SHARED="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/ws_shared"

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
    -v "${WS_SHARED}":/home/dev/ws_shared:rw \
    ${IMAGE}
