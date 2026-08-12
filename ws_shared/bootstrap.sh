#!/bin/bash
# Run ONCE per fresh container. Prepares everything that can't live in the image
# because it depends on the ws_shared mount (bridge package) or must be applied
# after the PX4 build (airframe mods).
#
#   bash ~/ws_shared/bootstrap.sh
#
# Safe to re-run (each step is idempotent or a rebuild).
set -e

WS=~/ws_shared
BR=$WS/dual_stage_rl/SITL_src/ps2rl_px4_bridge

echo "============================================================"
echo " PS2-RL powerloop bootstrap"
echo "============================================================"

# ---- 1. sanity: required repos present in ws_shared ----
for d in "$WS/PS2-RL" "$WS/dual_stage_rl"; do
  if [ ! -d "$d" ]; then
    echo "!! Missing $d — clone it into ws_shared first (see guide §Setup)."
    exit 1
  fi
done

# ---- 2. required code fix: vehicle_status -> vehicle_status_v1 (PX4 v1.16) ----
echo ">>> applying vehicle_status_v1 fix to bridge + calib nodes"
sed -i 's|"/fmu/out/vehicle_status"|"/fmu/out/vehicle_status_v1"|' \
    "$BR/ps2rl_px4_bridge/thrust_calib_node.py" \
    "$BR/ps2rl_px4_bridge/bridge_node.py" || true

# ---- 3. colcon symlink so the package is on the workspace ----
mkdir -p "$WS/src"
ln -sfn "$BR" "$WS/src/ps2rl_px4_bridge"

# ---- 4. apply PX4 airframe modifications (idempotent) ----
echo ">>> applying PX4 powerloop airframe setup"
bash "$WS/setup_px4_powerloop.sh"

# ---- 5. rebuild PX4 with the new airframe ----
echo ">>> building PX4 SITL (gz_x500_powerloop) — first build is slow"
cd ~/PX4-Autopilot
DONT_RUN=1 make px4_sitl gz_x500_powerloop

# ---- 6. build the bridge package ----
echo ">>> building ps2rl_px4_bridge"
cd "$WS"
source /opt/ros/jazzy/setup.bash
source ~/ws_ros2/install/setup.bash
colcon build --packages-select ps2rl_px4_bridge --base-paths src

echo ""
echo "============================================================"
echo " Bootstrap complete. Open a NEW shell (so it auto-sources"
echo " ws_shared/install), then verify:"
echo "   python3 -c \"from ps2rl_px4_bridge.policy_runner import PS2RLPolicy; print('OK')\""
echo "============================================================"
