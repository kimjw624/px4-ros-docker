#!/bin/bash
# Apply all PX4 modifications for the x500_powerloop airframe.
# Idempotent: safe to re-run. Because PX4 lives in the image (not a mount),
# run this once in each fresh container, then rebuild PX4.
set -e

PX4=~/PX4-Autopilot
MODELS=$PX4/Tools/simulation/gz/models
AIRFRAMES=$PX4/ROMFS/px4fmu_common/init.d-posix/airframes
DDS=$PX4/src/modules/uxrce_dds_client/dds_topics.yaml

echo ">>> [1/5] lightweight base model (mass 1.0, low inertia)"
if [ ! -d "$MODELS/x500_powerloop_base" ]; then
  cp -r "$MODELS/x500_base" "$MODELS/x500_powerloop_base"
  sed -i "s|<model name='x500_base'>|<model name='x500_powerloop_base'>|; s|<model name=\"x500_base\">|<model name=\"x500_powerloop_base\">|" "$MODELS/x500_powerloop_base/model.sdf"
  sed -i 's|<mass>2.0</mass>|<mass>1.0</mass>|' "$MODELS/x500_powerloop_base/model.sdf"
  sed -i 's|<ixx>0.02166666666666667</ixx>|<ixx>0.006</ixx>|' "$MODELS/x500_powerloop_base/model.sdf"
  sed -i 's|<iyy>0.02166666666666667</iyy>|<iyy>0.006</iyy>|' "$MODELS/x500_powerloop_base/model.sdf"
  sed -i 's|<izz>0.04000000000000001</izz>|<izz>0.011</izz>|' "$MODELS/x500_powerloop_base/model.sdf"
else
  echo "    x500_powerloop_base exists, skipping"
fi

echo ">>> [2/5] powerloop model (bumped thrust, points at light base)"
if [ ! -d "$MODELS/x500_powerloop" ]; then
  cp -r "$MODELS/x500" "$MODELS/x500_powerloop"
  sed -i 's/8.54858e-06/1.30e-05/g; s|<maxRotVelocity>1000.0</maxRotVelocity>|<maxRotVelocity>1500.0</maxRotVelocity>|g' "$MODELS/x500_powerloop/model.sdf"
  sed -i "s|<model name='x500'>|<model name='x500_powerloop'>|; s|<model name=\"x500\">|<model name=\"x500_powerloop\">|" "$MODELS/x500_powerloop/model.sdf"
  sed -i 's|<uri>model://x500_base</uri>|<uri>model://x500_powerloop_base</uri>|' "$MODELS/x500_powerloop/model.sdf"
else
  echo "    x500_powerloop exists, skipping"
fi

echo ">>> [3/5] airframe file 4100"
if [ ! -f "$AIRFRAMES/4100_gz_x500_powerloop" ]; then
  cp "$AIRFRAMES/4001_gz_x500" "$AIRFRAMES/4100_gz_x500_powerloop"
  sed -i 's/PX4_SIM_MODEL:=x500}/PX4_SIM_MODEL:=x500_powerloop}/' "$AIRFRAMES/4100_gz_x500_powerloop"
  sed -i 's/@name Gazebo x500/@name Gazebo x500 powerloop/' "$AIRFRAMES/4100_gz_x500_powerloop"
  sed -i 's/SIM_GZ_EC_MAX\([1-4]\) 1000/SIM_GZ_EC_MAX\1 1500/' "$AIRFRAMES/4100_gz_x500_powerloop"
  sed -i 's/MPC_THR_HOVER 0.60/MPC_THR_HOVER 0.18/' "$AIRFRAMES/4100_gz_x500_powerloop"
  cat >> "$AIRFRAMES/4100_gz_x500_powerloop" << 'EOF'

# --- powerloop: rate limits and gains ---
param set-default MC_ROLLRATE_MAX 1100
param set-default MC_PITCHRATE_MAX 1100
param set-default MC_YAWRATE_MAX 1100
param set-default MC_ROLLRATE_P 0.10
param set-default MC_ROLLRATE_D 0.0025
param set-default MC_PITCHRATE_P 0.16
param set-default MC_PITCHRATE_D 0.0025
param set-default MC_YAWRATE_P 0.12
EOF
else
  echo "    4100_gz_x500_powerloop exists, skipping"
fi

echo ">>> [4/5] register airframe in CMake"
if ! grep -q "4100_gz_x500_powerloop" "$AIRFRAMES/CMakeLists.txt"; then
  sed -i '/^\t4001_gz_x500$/a\\t4100_gz_x500_powerloop' "$AIRFRAMES/CMakeLists.txt"
else
  echo "    already registered, skipping"
fi

echo ">>> [5/5] add delivered-thrust topic to DDS"
if ! grep -q "/fmu/out/vehicle_thrust_setpoint" "$DDS"; then
  python3 - "$DDS" <<'PYEOF'
import sys
p = sys.argv[1]
s = open(p).read()
add = "  - topic: /fmu/out/vehicle_thrust_setpoint\n    type: px4_msgs::msg::VehicleThrustSetpoint\n"
i = s.index("subscriptions:")
open(p, "w").write(s[:i] + add + s[i:])
print("    inserted vehicle_thrust_setpoint")
PYEOF
else
  echo "    vehicle_thrust_setpoint already present, skipping"
fi

echo ""
echo ">>> PX4 powerloop setup complete."
echo ">>> Now rebuild PX4:  cd $PX4 && make px4_sitl gz_x500_powerloop"
