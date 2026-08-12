# Docker Setup

### Environment Stack
- Ubuntu 24.04
- ROS2 Jazzy
- PX4-Autopilot v1.16.0
- Gazebo Harmonic
- Micro XRCE DDS Agent
- QGC **on host**

### Folder Explanation: WS_Shared

`ws_shared`
- Host-mounted directory that survives image rebuilds. Keep all code, calibration files, and bundles here.

Files to keep in `ws_shared` (needed for reproduction):
- `PS2-RL/` — official code + checkpoint + reference (cloned)
- `dual_stage_rl/` — bridge repo (cloned; bridge at `SITL_src/ps2rl_px4_bridge`)
- `src/ps2rl_px4_bridge` — symlink into the bridge package (for colcon)
- `setup_px4_powerloop.sh` — recreates all PX4 edits (model, airframe, DDS)
- `poke_test.py` — frame/sign test
- `thrust_fit_1kg.yaml` — final calibrated thrust coefficients
- `deploy_bundle.tar.gz` — frozen snapshot of the bridge package (backup)

### Dockerfile changes (bake in so no per-session reinstall)

Add to the image:
```
# CPU JAX + policy deps for the deployment python (system 3.12, has rclpy)
RUN python3 -m pip install --break-system-packages \
    "jax==0.6.2" "jaxlib==0.6.2" "numpy==1.26.4" "scipy==1.14.1" "qpax==0.0.9"

# auto-source every shell (prevents "ros2 sees no topics")
RUN echo 'source /opt/ros/jazzy/setup.bash' >> /home/dev/.bashrc && \
    echo '[ -f ~/ws_shared/install/setup.bash ] && source ~/ws_shared/install/setup.bash' >> /home/dev/.bashrc && \
    echo 'export PYTHONPATH=$HOME/ws_shared/PS2-RL:$PYTHONPATH' >> /home/dev/.bashrc
```

### Basic Docker Commands

Building Image:
```
cd ~/px4-ros2-docker
xhost +local:docker
docker compose build
```

Start a container:
```
docker compose up -d
```

Open containers:
```
docker exec -it px4sitl bash
```

Exit container:
```
exit
```

Stop and remove containers:
```
docker compose down
```

### Check everything runs well

Note: Each terminal command includes the command to enter the container. Source ROS in every terminal (auto-sourced if the Dockerfile change above is applied).

Terminal 1: Start the bridge
```
xhost +local:docker
docker exec -it px4sitl bash
```
```
pkill -f MicroXRCEAgent; sleep 1
MicroXRCEAgent udp4 -p 8888
```

Terminal 2: Run PX4 SITL
```
xhost +local:docker
docker exec -it px4sitl bash
```
```
pkill -f 'px4|gz sim|ruby'; sleep 2
cd ~/PX4-Autopilot && make px4_sitl gz_x500
```

Terminal 3: Check ROS2 topics
```
xhost +local:docker
docker exec -it px4sitl bash
```
```
ros2 topic list
ros2 topic echo /fmu/out/vehicle_status_v1
```


# Setup PS2-RL

### Clone PS2-RL and Set Up Venv

The venv (Python 3.10, GPU JAX) is for **training only**. Deployment uses the container system Python (3.12, CPU JAX + rclpy). rclpy is compiled for 3.12 and cannot load in the 3.10 venv, so the two are kept separate.

Clone source code inside the Docker container:
```
xhost +local:docker
docker exec -it px4sitl bash
```
```
cd ~/ws_shared
git clone https://github.com/azizanlab/PS2-RL.git
cd PS2-RL
```

Add python3.10 as venv (**SKIP if already installed**):
```
sudo apt update
sudo apt install -y software-properties-common
sudo add-apt-repository ppa:deadsnakes/ppa -y
sudo apt update
sudo apt install python3.10 python3.10-venv python3.10-dev -y
```

Check installation:
```
python3.10 --version
```
- Should print Python 3.10.x

Enter venv:
```
python3.10 -m venv .venv
source .venv/bin/activate
```

Install the dependencies:
```
pip install --upgrade pip
pip install -r requirements.txt
```

Check whether JAX sees CUDA:
```
python -c "import jax; print(jax.devices())"
```
- Should print [CudaDevice(id=0)]

Run the repository's smoke test:
```
python -c "import ps2rl, qpax, jax; print('ok', jax.__version__)"
JAX_PLATFORMS=cpu python scripts/evaluate_phase2.py --system quadrotor --help
```
- Should print ok 0.6.2 and a list of help commands

Check whether the PS2-RL code functions well:
```
python scripts/evaluate_phase2.py --system quadrotor \
  --outputs_dir checkpoints/deployed_ps2 \
  --experiment checkpoints/deployed_ps2/quadrotor_ps2_learned \
  --weight_preference best_only
```
- Should show reasonable RMSE (safe_rate 1.0)

(Optional) Check evaluation results:
```
ls checkpoints/deployed_ps2/quadrotor_ps2_learned/evaluation/quadSAC_eval-*/
```

### Reference (gentle instead of power) trajectory data generation

Backup original code:
```
cp ps2rl/envs/assets/generate_quadrotor_powerloop_reference.py ps2rl/envs/assets/generate_quadrotor_gentleloop_reference.py
```

Comment the following lines:
```
# critical_speed = self.speed_margin_eps * np.sqrt(self.radius * self.gravity)
        # if self.speed <= critical_speed:
        #     raise ValueError(
        #         "Paper condition violated: requires ||v_l|| > eps*sqrt(r*g). "
        #         f"speed={self.speed:.6f}, eps*sqrt(r*g)={critical_speed:.6f} "
        #         f"(eps={self.speed_margin_eps}, r={self.radius}, g={self.gravity})."
        #     )
```

Create trajectory data:
```
python ps2rl/envs/assets/generate_quadrotor_gentleloop_reference.py --speed 1.0 --radius 1.5 --z-top 3.5 --z-bottom 0.5 --output-bundle ps2rl/envs/assets/quadrotor_gentleloop_reference.npz --output-npy ps2rl/envs/assets/quadrotor_gentleloop_reference_legacy.npy --output-figure ps2rl/envs/assets/quadrotor_gentleloop_reference.png --output-animation ps2rl/envs/assets/quadrotor_gentleloop_reference.gif --output-config-json ps2rl/envs/assets/quadrotor_gentleloop_reference_config.json
```

Check results:
```
ls -la ps2rl/envs/assets/quadrotor_gentleloop_reference.npz
python -c "import numpy as np; d=np.load('ps2rl/envs/assets/quadrotor_gentleloop_reference.npz'); s=d['states']; o=d['omega_cmd']; print('shape', s.shape); print('z min/max', float(s[:,2].min()), float(s[:,2].max())); print('max |omega|', float(np.abs(o).max())); print('q_w min', float(s[:,6].min()))"
python scripts/evaluate_phase1.py --system quadrotor --help
```
- gentleloop = ~473 steps, tiny omega. powerloop = 106 steps, max|omega|~10.8, q_w min -1.0

### Vanilla SAC Tracker Training (**On going, Give up for now**)

Run smoke test:
```
python scripts/train_vanilla_tracker.py --reference_path ps2rl/envs/assets/quadrotor_gentleloop_reference.npz --w_pos_xy 2.5 --w_pos_z 4.0 --w_vel 0.2 --w_att 2.0 --w_ref_omega_x 0.0 --w_ref_omega_y 0.0 --w_ref_omega_z 0.0 --base_set_c 8.0 --seed 0 --total_steps 20000 --save_final_weights --output_root gentle_vanilla --output_dir smoke
```

Check for:
1. Starts training without error (no shape mismatch from the 473-step reference).
2. Confirms the gentle reference loaded (~473 steps, not 106).
3. Saves to `outputs/gentle_vanilla/smoke/`.

Run the actual training (3M steps):
```
python scripts/train_vanilla_tracker.py --seed 1 --env_dt 0.02 --reward_mode trajectory_following --z_max 15.0 --actor_lr 1e-4 --critic_lr 5e-4 --alpha_lr 1e-4 --min_alpha 1e-1 --q_clip_abs 5e6 --w_pos_xy 2.5 --w_pos_z 3.0 --w_vel 4.0 --w_att 16.0 --w_ref_omega_x 0.10 --w_ref_omega_y 0.20 --w_ref_omega_z 0.05 --w_control_a 0.01 --w_control_omega 0.01 --base_set_c 8.0 --total_steps 5000000 --record_update_metrics --update_metric_every 200 --eval_episodes 10 --not_terminate_on_violation --save_final_weights --reference_path ps2rl/envs/assets/quadrotor_gentleloop_reference.npz --output_root gentle_vanilla --output_dir authors_recipe
```

### Phase I: Safe Arrival Policy Training

### Phase II: CIL Training


# Running SITL with My Model (General)


# Running SITL with Official Model (Power)

### Pre-check (PS2-RL Conventions)
- Frame: FLU (policy) ↔ FRD (PX4); ENU (policy) ↔ NED (PX4)
- $a_{cmd}$: mass-normalized acceleration command [0, 4g]
- $\omega_{cmd}$: angular rate command (rad/s)
- 10-D state: $[p, v, q]$
- The powerloop reference is **pure pitch**: max|ωy|~10.8, ωx=ωz=0. Roll/yaw the policy commands in flight is correction, not trajectory. **Pitch is the only axis that flies the loop.**

### Command Mapping: ($a_{cmd}, \omega_{cmd}$)
- Thrust: quadratic map `a = k2·thr² + k1·thr + k0`, inverted at runtime. Final (1 kg airframe): k0=-0.940572, k1=34.359792, k2=140.163116.
- Angular rates: rad/s, passed through (FLU→FRD conversion in the bridge).
- (The earlier linear `thr=(a+15.436)/21.362` was the 2 kg airframe — obsolete.)

### Add /fmu/out/vehicle_thrust_setpoint topic to DDS

Confirm layout:
```
grep -n "publications:\|subscriptions:" /home/dev/PX4-Autopilot/src/modules/uxrce_dds_client/dds_topics.yaml
```
Backup:
```
cp /home/dev/PX4-Autopilot/src/modules/uxrce_dds_client/dds_topics.yaml /home/dev/dds_topics.yaml.bak
```
Insert:
```
python3 - <<'EOF'
p = "/home/dev/PX4-Autopilot/src/modules/uxrce_dds_client/dds_topics.yaml"
s = open(p).read()
add = """  - topic: /fmu/out/vehicle_thrust_setpoint
    type: px4_msgs::msg::VehicleThrustSetpoint
"""
i = s.index("subscriptions:")
s = s[:i] + add + s[i:]
open(p, "w").write(s)
print("inserted")
EOF
```
Rebuild PX4, then check:
```
ros2 topic list | grep thrust
```

### Check whether the pretrained models work in simulation

Run the Python simulation:
```
source .venv/bin/activate
JAX_PLATFORMS=cpu python3 scripts/evaluate_phase2.py --system quadrotor \
  --outputs_dir checkpoints/deployed_ps2 \
  --experiment checkpoints/deployed_ps2/quadrotor_ps2_learned \
  --weight_preference best_only
```

Sanity checks — checkpoint / reference / config:
```
ls -la checkpoints/deployed_ps2/quadrotor_ps2_learned/
find checkpoints -maxdepth 2 -type d
ls -la ps2rl/envs/assets/*.npz ps2rl/envs/assets/*.npy
python3 -c "import json; c=json.load(open('checkpoints/deployed_ps2/quadrotor_ps2_learned/configs.json')); print(c['env'].get('reference_path'), c['env'].get('dt'), c['env'].get('include_time_features'))"
python3 -c "import json,pprint; pprint.pprint(json.load(open('checkpoints/deployed_ps2/quadrotor_ps2_learned/evaluation/quadSAC_eval-*/summary.json')))"
```

Components needed to deploy the model:
- Phase II model: best_weights.pkl, configs.json  (ships in the checkpoint dir)
- Phase I backup policy (learned; used by the CIL/QP)
- Reference trajectory: quadrotor_powerloop_reference.npz
- PS2-RL library code (ActorConfig, BCBF QP projector, actor+backup rollout+QP, obs layout, reference loading) — reached via `ps2rl_path`
- Bridge package `ps2rl_px4_bridge`

### Build the bridge package + required code fix

The calib and bridge nodes subscribe to `/fmu/out/vehicle_status`, renamed to `_v1` in PX4 v1.16. Without this fix the nodes hang forever "waiting to arm."
```
mkdir -p ~/ws_shared/src
ln -sfn ~/ws_shared/dual_stage_rl/SITL_src/ps2rl_px4_bridge ~/ws_shared/src/ps2rl_px4_bridge

BR=~/ws_shared/dual_stage_rl/SITL_src/ps2rl_px4_bridge/ps2rl_px4_bridge
sed -i 's|"/fmu/out/vehicle_status"|"/fmu/out/vehicle_status_v1"|' $BR/thrust_calib_node.py $BR/bridge_node.py

cd ~/ws_shared
colcon build --packages-select ps2rl_px4_bridge --base-paths src
source install/setup.bash
```

### Create the x500_powerloop airframe (light, high-thrust)

Everything below is packaged in `~/ws_shared/setup_px4_powerloop.sh` — run it once per fresh PX4 tree, then rebuild. The manual steps are kept for reference.

Final airframe values:
| Item | Value |
|---|---|
| mass | 1.0 kg |
| ixx/iyy | 0.006 |
| izz | 0.011 |
| motorConstant | 1.30e-05 |
| maxRotVelocity / SIM_GZ_EC_MAX | 1500 |
| MPC_THR_HOVER | 0.18 |
| MC_PITCHRATE_P | 0.16 |
| momentConstant / CA_ROTOR_KM | 0.016 / ±0.05 (stock) |

**setup_px4_powerloop.sh:**
```
#!/bin/bash
set -e
PX4=~/PX4-Autopilot
MODELS=$PX4/Tools/simulation/gz/models
AIRFRAMES=$PX4/ROMFS/px4fmu_common/init.d-posix/airframes

# light base (mass 1.0, low inertia)
cp -r $MODELS/x500_base $MODELS/x500_powerloop_base
sed -i "s|<model name='x500_base'>|<model name='x500_powerloop_base'>|; s|<model name=\"x500_base\">|<model name=\"x500_powerloop_base\">|" $MODELS/x500_powerloop_base/model.sdf
sed -i 's|<mass>2.0</mass>|<mass>1.0</mass>|' $MODELS/x500_powerloop_base/model.sdf
sed -i 's|<ixx>0.02166666666666667</ixx>|<ixx>0.006</ixx>|' $MODELS/x500_powerloop_base/model.sdf
sed -i 's|<iyy>0.02166666666666667</iyy>|<iyy>0.006</iyy>|' $MODELS/x500_powerloop_base/model.sdf
sed -i 's|<izz>0.04000000000000001</izz>|<izz>0.011</izz>|' $MODELS/x500_powerloop_base/model.sdf

# powerloop model (bumped thrust, points at light base)
cp -r $MODELS/x500 $MODELS/x500_powerloop
sed -i 's/8.54858e-06/1.30e-05/g; s|<maxRotVelocity>1000.0</maxRotVelocity>|<maxRotVelocity>1500.0</maxRotVelocity>|g' $MODELS/x500_powerloop/model.sdf
sed -i "s|<model name='x500'>|<model name='x500_powerloop'>|; s|<model name=\"x500\">|<model name=\"x500_powerloop\">|" $MODELS/x500_powerloop/model.sdf
sed -i 's|<uri>model://x500_base</uri>|<uri>model://x500_powerloop_base</uri>|' $MODELS/x500_powerloop/model.sdf

# airframe 4100
cp $AIRFRAMES/4001_gz_x500 $AIRFRAMES/4100_gz_x500_powerloop
sed -i 's/PX4_SIM_MODEL:=x500}/PX4_SIM_MODEL:=x500_powerloop}/' $AIRFRAMES/4100_gz_x500_powerloop
sed -i 's/@name Gazebo x500/@name Gazebo x500 powerloop/' $AIRFRAMES/4100_gz_x500_powerloop
sed -i 's/SIM_GZ_EC_MAX\([1-4]\) 1000/SIM_GZ_EC_MAX\1 1500/' $AIRFRAMES/4100_gz_x500_powerloop
sed -i 's/MPC_THR_HOVER 0.60/MPC_THR_HOVER 0.18/' $AIRFRAMES/4100_gz_x500_powerloop
cat >> $AIRFRAMES/4100_gz_x500_powerloop << 'EOF'

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

# register in CMake
grep -q "4100_gz_x500_powerloop" $AIRFRAMES/CMakeLists.txt || \
  sed -i '/^\t4001_gz_x500$/a\\t4100_gz_x500_powerloop' $AIRFRAMES/CMakeLists.txt

# DDS delivered-thrust topic
DDS=$PX4/src/modules/uxrce_dds_client/dds_topics.yaml
grep -q "/fmu/out/vehicle_thrust_setpoint" $DDS || python3 - <<PYEOF
p="$DDS"; s=open(p).read()
add="  - topic: /fmu/out/vehicle_thrust_setpoint\n    type: px4_msgs::msg::VehicleThrustSetpoint\n"
i=s.index("subscriptions:"); open(p,"w").write(s[:i]+add+s[i:])
PYEOF
echo "done — now: cd $PX4 && make px4_sitl gz_x500_powerloop"
```

Run and build:
```
chmod +x ~/ws_shared/setup_px4_powerloop.sh
~/ws_shared/setup_px4_powerloop.sh
cd ~/PX4-Autopilot && make px4_sitl gz_x500_powerloop
```
(Note: do NOT add MC_TPA_BREAK_P / MC_TPA_RATE_P — those param names error on v1.16.)

### Verify hover before anything else

Always confirm hover ~0.178 before flying the policy. A wrong MPC_THR_HOVER silently breaks takeoff/lineup and poisons the whole flight.

Terminal 1,2: DDS + PX4 SITL (gz_x500_powerloop). In the pxh> console:
```
commander takeoff
listener vehicle_thrust_setpoint
commander land
```
- xyz[2] should read ~ -0.178. If not, fix params (usually MPC_THR_HOVER).

### Thrust calibration on x500_powerloop

Only needed if the airframe mass/thrust changed. Levels must bracket hover (~0.18). Good fit = monotonic, k2>0, RMS residual < 0.1. Keep ~5 levels + settle 8.0 (more levels drift and the last pulse corrupts the fit).

Terminals: DDS + PX4 SITL running. Calib terminal (deactivate venv, source ROS):
```
cd ~/ws_shared
colcon build --packages-select ps2rl_px4_bridge --base-paths src
source install/setup.bash

ros2 run ps2rl_px4_bridge thrust_calib --ros-args \
    -p calib_altitude:=30.0 \
    -p output_yaml:=/tmp/thrust_fit_1kg.yaml \
    -p pulse_duration:=0.6 \
    -p pulse_settle_skip:=0.20 \
    -p settle_duration:=8.0 \
    -p 'thrust_levels:=[0.12, 0.16, 0.20, 0.24, 0.28]'
```

Save and record the coefficients:
```
cat /tmp/thrust_fit_1kg.yaml
cp /tmp/thrust_fit_1kg.yaml ~/ws_shared/thrust_fit_1kg.yaml
```
Final: k0=-0.940572, k1=34.359792, k2=140.163116.

### Open-loop frame/sign poke test

Validates frame signs + rate tracking + thrust map using the bridge's own conversion code, one axis at a time. (Copy `poke_test.py` from ws_shared; source below.) With the correct build, all axes track in sign; the "crazy" at LAND is the PX4 land handoff and is benign.

Run (DDS + PX4 up, deactivate venv):
```
deactivate 2>/dev/null
source /opt/ros/jazzy/setup.bash
source ~/ws_shared/install/setup.bash
python3 -c "from ps2rl_px4_bridge import frame_transforms; print('bridge import OK')"
python3 poke_test.py
```

Summary:
```
python3 - <<'EOF'
import csv
rows=list(csv.DictReader(open('/tmp/poke_test.csv')))
from collections import defaultdict
byp=defaultdict(list)
for r in rows: byp[r['phase']].append(r)
for ph in ['ROLL','PITCH','YAW','TUP','TDN']:
    rs=byp.get(ph,[])
    if not rs: continue
    mid=rs[len(rs)//2]; last=rs[-1]
    print(f"{ph:6s} | flu_cmd=({mid['wx_flu_cmd']},{mid['wy_flu_cmd']},{mid['wz_flu_cmd']}) "
          f"frd_cmd=({mid['wx_frd_cmd']},{mid['wy_frd_cmd']},{mid['wz_frd_cmd']}) "
          f"meas=({mid['wx_meas']},{mid['wy_meas']},{mid['wz_meas']}) "
          f"| roll={last['roll_deg']} pitch={last['pitch_deg']} yaw={last['yaw_deg']} "
          f"| a_cmd={mid['a_cmd']} thr={mid['thr']} pz={last['pz']}")
EOF
```
(Note: in poke_test.py, the THRUST=ThrustModel(...) line must use the final 1 kg coefficients k0=-0.940572, k1=34.359792, k2=140.163116.)

### Configure bridge.yaml

Environment check (confirms venv 3.10 ≠ container 3.12):
```
# 1. system python (has rclpy) - jax?
deactivate 2>/dev/null
python3 -c "import sys; print('system python:', sys.executable)"
python3 -c "import rclpy; print('  rclpy: OK')" 2>&1 | tail -1
python3 -c "import jax; print('  jax:', jax.__version__)" 2>&1 | tail -1

# 2. venv (has jax) - rclpy?
source ~/ws_shared/PS2-RL/.venv/bin/activate
python3 -c "import sys; print('venv python:', sys.executable)"
python3 -c "import jax; print('  jax:', jax.__version__)" 2>&1 | tail -1
python3 -c "import rclpy; print('  rclpy:', 'OK')" 2>&1 | tail -1

# 3. versions must match (they don't: 3.12 vs 3.10)
deactivate 2>/dev/null
python3 --version
source ~/ws_shared/PS2-RL/.venv/bin/activate
python3 --version
deactivate 2>/dev/null
```

Install deps into the container python (skip if in Dockerfile):
```
python3 -m pip install --break-system-packages \
    "jax==0.6.2" "jaxlib==0.6.2" "numpy==1.26.4" "scipy==1.14.1" "qpax==0.0.9"
```

Write bridge.yaml (final good-run config):
```
cat > ~/ws_shared/dual_stage_rl/SITL_src/ps2rl_px4_bridge/config/bridge.yaml << 'EOF'
/ps2rl_px4_bridge:
  ros__parameters:
    ps2rl_path: "/home/dev/ws_shared/PS2-RL"
    run_dir: "/home/dev/ws_shared/PS2-RL/checkpoints/deployed_ps2/quadrotor_ps2_learned"
    checkpoint: "best"
    learned_backup_policy_path: ""
    reference_path: "/home/dev/ws_shared/PS2-RL/ps2rl/envs/assets/quadrotor_powerloop_reference.npz"
    jax_platform: "cpu"
    jax_single_thread: true

    policy_rate: 50.0
    policy_timer_oversample: 1.0
    setpoint_rate: 50.0

    thrust_model: "quadratic"
    hover_thrust: 0.178
    thrust_k0: -0.940572
    thrust_k1: 34.359792
    thrust_k2: 140.163116
    thrust_min: 0.02
    thrust_max: 1.0

    origin_offset_enu: [0.0, 0.0, 0.0]
    takeoff_altitude: 2.5
    lineup_distance: 10.0
    lineup_position_tol: 0.35
    lineup_settle_time: 3.0
    dash_speed_tol: 0.15
    dash_tilt_tol_deg: 4.0
    dash_pos_tol: 0.10
    dash_accel: 3.0
    dash_timeout: 15.0
    recover_altitude: 3.0
    recover_time: 4.0

    z_abort_margin: 1.0
    arena_radius: 40.0
    odom_timeout: 0.30
    auto_start: true

    log_csv: "/tmp/ps2rl_flight.csv"
EOF
```

Rebuild (config is copied into install/ at build — always rebuild after editing):
```
cd ~/ws_shared
colcon build --packages-select ps2rl_px4_bridge --base-paths src
```

Verify the unified environment:
```
deactivate 2>/dev/null
source /opt/ros/jazzy/setup.bash
source ~/ws_shared/install/setup.bash
export PYTHONPATH=~/ws_shared/PS2-RL:$PYTHONPATH
python3 -c "import rclpy; print('rclpy OK')"
python3 -c "import jax; print('jax', jax.__version__, jax.devices())"
python3 -c "import qpax; print('qpax OK')"
python3 -c "import ps2rl; print('ps2rl OK')"
python3 -c "from ps2rl_px4_bridge.policy_runner import PS2RLPolicy; print('BRIDGE IMPORTS OK')"
```
- jax.devices() should show [CpuDevice(id=0)]; last line BRIDGE IMPORTS OK.

### Run the flight

Terminals (each sourced; do NOT activate venv for the bridge).

Terminal 1: DDS
```
MicroXRCEAgent udp4 -p 8888
```
Terminal 2: PX4 SITL (clean restart every time)
```
pkill -f 'px4|gz sim|ruby'; sleep 2
cd ~/PX4-Autopilot && make px4_sitl gz_x500_powerloop
```
Terminal 3: bridge
```
deactivate 2>/dev/null
source /opt/ros/jazzy/setup.bash
source ~/ws_shared/install/setup.bash
cp /tmp/ps2rl_flight.csv ~/ws_shared/flight_$(date +%H%M%S).csv 2>/dev/null
ros2 launch ps2rl_px4_bridge ps2rl_sitl.launch.py
```

auto_start runs BOOT→ARM→TAKEOFF→LINEUP→DASH→POLICY→RECOVER→LAND.
Healthy: obs_dim=26, handover dev pos~0.01/speed~0.15/tilt~3°, 106 steps, mean sim dt~20ms, latency~4ms, 0% thrust saturation, position RMS~2 m.

### Analyze

```
python3 ~/ws_shared/dual_stage_rl/SITL_src/ps2rl_px4_bridge/plot_trajectory.py /tmp/ps2rl_flight.csv
python3 ~/ws_shared/dual_stage_rl/SITL_src/ps2rl_px4_bridge/analyze_flight.py /tmp/ps2rl_flight.csv
```
Read pitch (axis y) — it flies the loop. Roll/yaw are corrections; noisy is normal.

### Rate-PID tuning (next step, not yet solved)

Loop is pure pitch; the sim-to-SITL gap is pitch rate-loop lag (training omits rotational dynamics, assumes instant ω). Tune MC_PITCHRATE_P/D one step at a time, clean-restart each time, watch axis y tau/corr in analyze_flight. Change one thing per flight.

Edit gain, restart, re-fly, analyze:
```
sed -i 's/MC_PITCHRATE_P 0.16/MC_PITCHRATE_P 0.20/' \
    ~/PX4-Autopilot/ROMFS/px4fmu_common/init.d-posix/airframes/4100_gz_x500_powerloop
pkill -f 'px4|gz sim|ruby'; sleep 2
cd ~/PX4-Autopilot && make px4_sitl gz_x500_powerloop
```

### Gotchas (each cost real debugging time)

1. Unsourced shell → `ros2 topic list` empty (PX4 tx>0 but ROS sees nothing). Source every terminal.
2. Gazebo caches models. After ANY model/airframe edit: `pkill -f 'px4|gz sim|ruby'; sleep 2` then rebuild.
3. MPC_THR_HOVER must match real hover (0.18). Stock 0.60 poisons takeoff/lineup.
4. vehicle_status → vehicle_status_v1 (v1.16) or nodes hang "waiting to arm".
5. Two pythons: venv 3.10 GPU JAX = training; system 3.12 CPU JAX+rclpy = deploy. rclpy won't load in the venv.
6. Control-rate readout is wall-clock (may show 42/62 Hz). Real check: mean sim dt ~20 ms over 106 steps (span ~2.1 s).
7. origin_offset_enu: keep [0,0,0]. Nonzero z disturbed the takeoff→entry sequence even though the obs is offset-corrected.
8. Rebuild after every bridge.yaml edit (node reads install/, not source).
9. Do not add MC_TPA_* params — they error on v1.16.
10. thrust_calib: 5 levels + settle 8.0, bracket hover; more levels drift and corrupt the last pulse.

### Persist everything into Docker

- Dockerfile: pip deps + auto-source (top of this doc).
- ws_shared (persistent): PS2-RL, dual_stage_rl, src/ symlink, setup_px4_powerloop.sh, poke_test.py, thrust_fit_1kg.yaml, deploy_bundle.tar.gz, this md.
- Fresh PX4 tree: run setup_px4_powerloop.sh, then make px4_sitl gz_x500_powerloop.
- Fresh workspace: apply vehicle_status_v1 fix, colcon build.

### Current status

Reached a stable, complete powerloop flight (position RMS ~2 m) — recognizable but loose; undershoots the top (~3.0 vs 3.5 m). Integration is correct (policy, frames, timing, thrust map, entry), 0% thrust saturation. Remaining: pitch rate-loop tuning to tighten tracking.
