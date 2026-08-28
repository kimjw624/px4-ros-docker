# PS2-RL Powerloop in PX4/Gazebo SITL

Reproducible setup for the deployed PS2-RL powerloop policy in PX4 SITL. Everything lives in the `px4-ros-docker` repo (Docker + scripts) with PS2-RL and dual_stage_rl as git submodules. This reaches the best working configuration: a stable, complete powerloop flight (position RMS ~2 m). Tracking tuning continues from there (see "Rate-PID tuning").

---

# Quick Start (fresh machine)

```
# 1. Clone recursively — pulls submodules PS2-RL + dual_stage_rl
git clone --recursive https://github.com/kimjw624/px4-ros-docker.git
cd px4-ros-docker

# 2. Build + start the container
xhost +local:docker
docker compose build
docker compose up -d
docker exec -it px4sitl bash

# 3. One-time bootstrap: applies PX4 mods, builds PX4 airframe, builds the bridge
bash ~/ws_shared/bootstrap.sh

# 4. Open a NEW shell so it auto-sources ws_shared/install
docker exec -it px4sitl bash
```

After this, skip to "Run the flight". The sections in between are reference / explanation / one-off setup (training, calibration) you only need if something breaks or you are changing the airframe.

**IMPORTANT**: `docker compose down` removes the container, and PX4 lives inside the image (not the ws_shared mount), so the PX4 airframe mods are lost on a full teardown. After any `down` + `up`, re-run `bash ~/ws_shared/bootstrap.sh` (it is idempotent). Your ws_shared files (repos, calibration, scripts) always survive.

---

# Environment Stack

- Ubuntu 24.04, ROS 2 Jazzy, PX4-Autopilot v1.16.0, Gazebo Harmonic
- Micro XRCE-DDS Agent, QGC **on host**
- Two Pythons: **venv 3.10 (GPU JAX) = training**; **container system 3.12 (CPU JAX + rclpy) = deployment**. rclpy is built for 3.12 and cannot load in the 3.10 venv, so they are separate. CPU JAX is baked into the image.

# Repo layout

```
px4-ros-docker/
├── Dockerfile              # builds PX4 v1.16 + ROS + Gazebo + CPU JAX
├── docker-compose.yml
├── run.sh
└── ws_shared/              # bind-mounted into the container, persistent
    ├── bootstrap.sh            # one-shot container setup
    ├── setup_px4_powerloop.sh  # PX4 airframe/model/DDS edits (idempotent)
    ├── poke_test.py            # frame/sign test
    ├── thrust_fit_1kg.yaml     # calibrated thrust coefficients
    ├── experiments/            # timestamped SITL results (local, git-ignored)
    ├── PS2-RL/                 # submodule (upstream, read-only)
    └── dual_stage_rl/          # submodule (yours; bridge in SITL_src/ps2rl_px4_bridge)
```

---

# Docker Commands

Build image (from the repo root):

```
cd ~/px4-ros-docker
xhost +local:docker
docker compose build
```

Start / enter / exit / teardown:

```
docker compose up -d
docker exec -it px4sitl bash
exit
docker compose down
```

---

# Check the base container runs

Each terminal enters the container; ROS is auto-sourced by the image's .bashrc.

Terminal 1: DDS agent

```
docker exec -it px4sitl bash
```

```
pkill -f MicroXRCEAgent; sleep 1
MicroXRCEAgent udp4 -p 8888
```

Terminal 2: PX4 SITL (stock x500 for this base check)

```
docker exec -it px4sitl bash
```

```
pkill -f 'px4|gz sim|ruby'; sleep 2
cd ~/PX4-Autopilot && make px4_sitl gz_x500
```

Terminal 3: ROS topics

```
docker exec -it px4sitl bash
```

```
ros2 topic list
ros2 topic echo /fmu/out/vehicle_status_v1
```

If topics appear, the base works. (After bootstrap you will use `gz_x500_powerloop` instead of `gz_x500`.)

---

# What bootstrap.sh does (for reference)

`bash ~/ws_shared/bootstrap.sh` runs these, so you do NOT do them by hand:

1. Applies the `vehicle_status` -> `vehicle_status_v1` fix to the bridge + calib nodes (PX4 v1.16 renamed the topic; without it the nodes hang "waiting to arm").
2. Creates the colcon symlink `ws_shared/src/ps2rl_px4_bridge`.
3. Runs `setup_px4_powerloop.sh` (airframe/model/DDS edits, idempotent).
4. Rebuilds PX4 with the `gz_x500_powerloop` airframe.
5. Builds the `ps2rl_px4_bridge` package.

The manual equivalents are documented below in case you need to run one in isolation.

---

# (Optional) PS2-RL venv — training / pure-sim check only

Skip entirely if you are only running the SITL deployment (the image already has CPU JAX). The venv is for training or the optional Python-only policy check.

ALL PS2-RL commands run from `~/ws_shared/PS2-RL`.

```
cd ~/ws_shared/PS2-RL
python3.10 --version          # 3.10.x (installed in the image)
python3.10 -m venv .venv
source .venv/bin/activate
pip install --upgrade pip
pip install -r requirements.txt
```

Check JAX sees CUDA (venv has GPU JAX):

```
python -c "import jax; print(jax.devices())"
```

- [CudaDevice(id=0)]

Pure-sim policy check (from ~/ws_shared/PS2-RL):

```
JAX_PLATFORMS=cpu python scripts/evaluate_phase2.py --system quadrotor \
  --outputs_dir checkpoints/deployed_ps2 \
  --experiment checkpoints/deployed_ps2/quadrotor_ps2_learned \
  --weight_preference best_only
```

- Should show reasonable RMSE (safe_rate 1.0).

---

# (Optional) Gentle-loop reference generation — training only

Run from `~/ws_shared/PS2-RL` inside the venv.

Backup, then comment the paper-condition check in the copied file:

```
cd ~/ws_shared/PS2-RL
cp ps2rl/envs/assets/generate_quadrotor_powerloop_reference.py ps2rl/envs/assets/generate_quadrotor_gentleloop_reference.py
```

Comment out in the copy:

```
# critical_speed = self.speed_margin_eps * np.sqrt(self.radius * self.gravity)
#         if self.speed <= critical_speed:
#             raise ValueError(...)
```

Generate:

```
python ps2rl/envs/assets/generate_quadrotor_gentleloop_reference.py --speed 1.0 --radius 1.5 --z-top 3.5 --z-bottom 0.5 --output-bundle ps2rl/envs/assets/quadrotor_gentleloop_reference.npz --output-npy ps2rl/envs/assets/quadrotor_gentleloop_reference_legacy.npy --output-figure ps2rl/envs/assets/quadrotor_gentleloop_reference.png --output-animation ps2rl/envs/assets/quadrotor_gentleloop_reference.gif --output-config-json ps2rl/envs/assets/quadrotor_gentleloop_reference_config.json
```

Check:

```
python -c "import numpy as np; d=np.load('ps2rl/envs/assets/quadrotor_gentleloop_reference.npz'); s=d['states']; o=d['omega_cmd']; print('shape', s.shape, 'z', float(s[:,2].min()), float(s[:,2].max()), 'max|omega|', float(np.abs(o).max()), 'q_w min', float(s[:,6].min()))"
```

- gentleloop ~473 steps, tiny omega. (powerloop = 106 steps, max|omega|~10.8.)

# (Optional) Vanilla SAC tracker training (paused)

From `~/ws_shared/PS2-RL` in the venv. Smoke test:

```
python scripts/train_vanilla_tracker.py --reference_path ps2rl/envs/assets/quadrotor_gentleloop_reference.npz --w_pos_xy 2.5 --w_pos_z 4.0 --w_vel 0.2 --w_att 2.0 --w_ref_omega_x 0.0 --w_ref_omega_y 0.0 --w_ref_omega_z 0.0 --base_set_c 8.0 --seed 0 --total_steps 20000 --save_final_weights --output_root gentle_vanilla --output_dir smoke
```

Full run (3M steps):

```
python scripts/train_vanilla_tracker.py --seed 1 --env_dt 0.02 --reward_mode trajectory_following --z_max 15.0 --actor_lr 1e-4 --critic_lr 5e-4 --alpha_lr 1e-4 --min_alpha 1e-1 --q_clip_abs 5e6 --w_pos_xy 2.5 --w_pos_z 3.0 --w_vel 4.0 --w_att 16.0 --w_ref_omega_x 0.10 --w_ref_omega_y 0.20 --w_ref_omega_z 0.05 --w_control_a 0.01 --w_control_omega 0.01 --base_set_c 8.0 --total_steps 5000000 --record_update_metrics --update_metric_every 200 --eval_episodes 10 --not_terminate_on_violation --save_final_weights --reference_path ps2rl/envs/assets/quadrotor_gentleloop_reference.npz --output_root gentle_vanilla --output_dir authors_recipe
```

---

# Running SITL with the Official Model (Powerloop)

### Conventions

- Frames: FLU (policy) <-> FRD (PX4); ENU (policy) <-> NED (PX4)
- a_cmd: mass-normalized acceleration [0, 4g]; omega: rad/s; 10-D state [p, v, q]
- The powerloop reference is **pure pitch**: max|wy|~10.8, wx=wz=0. Any roll/yaw the policy commands in flight is correction, not trajectory. **Pitch flies the loop.**

### Thrust mapping (final, 1 kg airframe)

- Quadratic `a = k2*thr^2 + k1*thr + k0`, inverted at runtime: k0=-0.940572, k1=34.359792, k2=140.163116.
- Angular rates pass through (FLU->FRD in the bridge).
- (Obsolete: linear `thr=(a+15.436)/21.362` was the 2 kg airframe.)

### x500_powerloop airframe values (applied by setup_px4_powerloop.sh)

|Item|Value|
|---|---|
|mass|1.0 kg|
|ixx/iyy|0.006|
|izz|0.011|
|motorConstant|1.30e-05|
|maxRotVelocity / SIM_GZ_EC_MAX|1500|
|MPC_THR_HOVER|0.18|
|MC_PITCHRATE_P|0.16|
|momentConstant / CA_ROTOR_KM|0.016 / +-0.05 (stock)|

(Do NOT add MC_TPA_BREAK_P / MC_TPA_RATE_P — those names error on v1.16.)

### bridge.yaml

Based on the airframe you are using, you must use the correct px4_bridge.yaml files.

Normal x500:
```
ros2 launch ps2rl_px4_bridge ps2rl_sitl.launch.py \
    config:=$HOME/PS2-RL/config/bridge_x500.yaml
```

Powerloop x500:
```
ros2 launch ps2rl_px4_bridge ps2rl_sitl.launch.py \
    config:=$HOME/PS2-RL/config/bridge_x500_powerloop.yaml
```

The config is committed in the dual_stage_rl submodule at `SITL_src/ps2rl_px4_bridge/config/bridge.yaml`. It should already contain the final values below. Only rewrite it if it drifted. **Rebuild after any edit** (the node reads the copy in install/, not the source).

```
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
```

Rebuild after editing:

```
cd ~/ws_shared
colcon build --packages-select ps2rl_px4_bridge --base-paths src
```

### Verify the deployment environment

```
deactivate 2>/dev/null
source /opt/ros/jazzy/setup.bash
source ~/ws_shared/install/setup.bash
export PYTHONPATH=~/ws_shared/PS2-RL:$PYTHONPATH
python3 -c "import rclpy; print('rclpy OK')"
python3 -c "import jax; print('jax', jax.__version__, jax.devices())"
python3 -c "import qpax, ps2rl; print('qpax + ps2rl OK')"
python3 -c "from ps2rl_px4_bridge.policy_runner import PS2RLPolicy; print('BRIDGE IMPORTS OK')"
```

- jax.devices() -> [CpuDevice(id=0)]; ends with BRIDGE IMPORTS OK.
- (PYTHONPATH is only for this standalone check; the running bridge inserts ps2rl_path itself.)

### Verify hover BEFORE flying the policy

A wrong MPC_THR_HOVER silently breaks takeoff/lineup. Confirm ~0.178.

Terminals 1,2: DDS + PX4 SITL (gz_x500_powerloop). In the pxh> console:

```
commander takeoff
listener vehicle_thrust_setpoint
commander land
```

- xyz[2] ~ -0.178. If not, fix MPC_THR_HOVER in the airframe and rebuild PX4.

### Run the flight

Three terminals (each auto-sourced; do NOT activate the venv for the bridge).

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
cp /tmp/ps2rl_flight.csv ~/ws_shared/flight_$(date +%H%M%S).csv 2>/dev/null
ros2 launch ps2rl_px4_bridge ps2rl_sitl.launch.py
```

auto_start runs BOOT->ARM->TAKEOFF->LINEUP->DASH->POLICY->RECOVER->LAND. Healthy: obs_dim=26, handover dev pos~0.01/speed~0.15/tilt~3deg, 106 steps, mean sim dt~20 ms, latency~4 ms, 0% thrust saturation, position RMS~2 m.

The command above is the old direct-launch workflow for the nominal PS2-RL
policy fine-tuned with CIL. It is still supported, but it writes the CSV to
`/tmp`. Use the organized experiment commands below for policy comparisons.

### Organized policy comparison runs

The experiment runner keeps every flight in its own timestamped directory and
does not mix the nominal and delay-policy outputs:

```
~/ws_shared/experiments/ps2rl_sitl/<timestamp>-<label>/
├── run_metadata.json       # command, checkpoint path/hash, source commit
├── bridge_config.yaml      # exact bridge config used for this run
├── bridge.log              # complete ROS/bridge terminal output
├── flight.csv              # state, reference, raw/safe action, CIL diagnostics
├── analysis.txt
├── plot.log
├── policy/                 # configs.json + summary.json snapshot when present
└── plots/
    ├── trajectory.png
    └── trajectory_cil.png
```

The whole `experiments/` directory is local and git-ignored. After LAND, press
Ctrl-C once in the bridge terminal. The wrapper then stops `ros2 launch`, runs
the analysis/plot scripts, and prints the saved experiment directory.

Keep each deployed policy in a separate directory:

|Label|Policy directory|Observation|CIL/QP|
|---|---|---|---|
|`nominal_no_delay_no_cil`|`checkpoints/sitl_delay_comparison/policies/nominal_no_delay_no_cil`|26D|off|
|`delay_d5_j2_h5_seed4`|`checkpoints/sitl_delay_comparison/policies/delay_d5_j2_h5_seed4`|46D (5 previous commands)|off|
|`nominal_cil_learned`|`checkpoints/deployed_ps2/quadrotor_ps2_learned`|26D|on, learned backup|
|`delay_cil_<run>`|choose after training completes|saved delay layout|on, saved CIL config|

`configs.json` is authoritative. A vanilla deployment must contain
`use_projection=false`; a CIL deployment must contain `use_projection=true`.
Do not disable CIL on the already CIL-fine-tuned actor and call it a vanilla
baseline. The vanilla nominal baseline uses the original pre-CIL checkpoint.

All commands below run in Terminal 3, outside the Python 3.10 training venv,
with DDS and a freshly restarted `gz_x500_powerloop` already running:

```
deactivate 2>/dev/null || true
source /opt/ros/jazzy/setup.bash
source ~/ws_shared/install/setup.bash
```

#### Vanilla nominal — no delay, no CIL

This is the controlled baseline for testing whether delay/history training
improves SITL tracking:

```
python3 ~/ws_shared/dual_stage_rl/SITL_src/ps2rl_px4_bridge/run_sitl_experiment.py \
  --label nominal_no_delay_no_cil \
  --config ~/ws_shared/dual_stage_rl/SITL_src/ps2rl_px4_bridge/config/bridge_x500_powerloop.yaml \
  --run-dir ~/ws_shared/PS2-RL/checkpoints/sitl_delay_comparison/policies/nominal_no_delay_no_cil \
  --checkpoint final
```

Expected startup/result diagnostics: `obs_dim=26`, no delay/history, and
`proj_norm=0`, `slack=0` throughout the policy segment.

#### Vanilla delay-trained — delay/history, no CIL

The current delay policy was trained with actuator delay `5 +/- 2` steps and a
five-command history:

```
python3 ~/ws_shared/dual_stage_rl/SITL_src/ps2rl_px4_bridge/run_sitl_experiment.py \
  --label delay_d5_j2_h5_seed4 \
  --config ~/ws_shared/dual_stage_rl/SITL_src/ps2rl_px4_bridge/config/bridge_x500_powerloop_delay.yaml \
  --run-dir ~/ws_shared/PS2-RL/checkpoints/sitl_delay_comparison/policies/delay_d5_j2_h5_seed4 \
  --checkpoint final
```

Expected startup/result diagnostics: `obs_dim=46`, `hist_action=5`, and
`proj_norm=0`, `slack=0` throughout the policy segment.

#### Nominal PS2-RL — no delay, CIL enabled

This is the existing actor fine-tuned with CIL and a learned backup policy. It
is a separate safety/controller experiment, not the vanilla nominal baseline:

```
python3 ~/ws_shared/dual_stage_rl/SITL_src/ps2rl_px4_bridge/run_sitl_experiment.py \
  --label nominal_cil_learned \
  --config ~/ws_shared/dual_stage_rl/SITL_src/ps2rl_px4_bridge/config/bridge_x500_powerloop.yaml \
  --run-dir ~/ws_shared/PS2-RL/checkpoints/deployed_ps2/quadrotor_ps2_learned \
  --checkpoint best
```

Expected startup diagnostics: `obs_dim=26`, `backup=learned`. Nonzero
`proj_norm` means the CIL/QP changed the raw actor command.

#### Future delay-trained PS2-RL — delay/history, CIL enabled

Run this only after training finishes and the new run directory contains its
own `configs.json`, selected weights, and any required backup-policy weights:

```
python3 ~/ws_shared/dual_stage_rl/SITL_src/ps2rl_px4_bridge/run_sitl_experiment.py \
  --label delay_cil_<run> \
  --config ~/ws_shared/dual_stage_rl/SITL_src/ps2rl_px4_bridge/config/bridge_x500_powerloop_delay.yaml \
  --run-dir ~/ws_shared/PS2-RL/checkpoints/sitl_delay_comparison/policies/<delay-cil-run-directory> \
  --checkpoint best
```

Before flying, check that its `configs.json` reports the expected delay/history
layout and `use_projection=true`. Replace both angle-bracket placeholders with
the final training-run name. Do not reuse the current vanilla delay directory.

### Analyze

```
python3 ~/ws_shared/dual_stage_rl/SITL_src/ps2rl_px4_bridge/plot_trajectory.py /tmp/ps2rl_flight.csv
python3 ~/ws_shared/dual_stage_rl/SITL_src/ps2rl_px4_bridge/analyze_flight.py /tmp/ps2rl_flight.csv
```

Read pitch (axis y) — it flies the loop. Roll/yaw are corrections; noisy is normal.

---

# Thrust calibration (only if airframe mass/thrust changed)

The committed coefficients are for the 1 kg airframe. Redo only if you change the airframe. Levels must bracket hover (~0.18). Good fit = monotonic, k2>0, RMS residual < 0.1. Keep ~5 levels + settle 8.0 (more levels drift; the last pulse corrupts the fit).

DDS + PX4 SITL running. Calib terminal:

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

Record and save:

```
cat /tmp/thrust_fit_1kg.yaml
cp /tmp/thrust_fit_1kg.yaml ~/ws_shared/thrust_fit_1kg.yaml
```

Put k0/k1/k2 into bridge.yaml and rebuild. Final: k0=-0.940572, k1=34.359792, k2=140.163116.

---

# Open-loop frame/sign poke test (optional sanity)

Validates frame signs + rate tracking + thrust map using the bridge's own conversion code, one axis at a time. `poke_test.py` is in ws_shared. In it, the `THRUST=ThrustModel(...)` line must use the final 1 kg coefficients. With a correct build all axes track in sign; the "crazy" at LAND is the PX4 land handoff and is benign.

DDS + PX4 up:

```
python3 -c "from ps2rl_px4_bridge import frame_transforms; print('bridge import OK')"
python3 ~/ws_shared/poke_test.py
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

---

# Rate-PID tuning (next step, not yet solved)

Loop is pure pitch; the sim-to-SITL gap is pitch rate-loop lag (training omits rotational dynamics, assumes instant omega). Tune MC_PITCHRATE_P/D one step at a time, clean-restart each time, watch axis y tau/corr in analyze_flight.

```
sed -i 's/MC_PITCHRATE_P 0.16/MC_PITCHRATE_P 0.20/' \
    ~/PX4-Autopilot/ROMFS/px4fmu_common/init.d-posix/airframes/4100_gz_x500_powerloop
pkill -f 'px4|gz sim|ruby'; sleep 2
cd ~/PX4-Autopilot && make px4_sitl gz_x500_powerloop
```

---

# Gotchas (each cost real debugging time)

1. Unsourced shell -> `ros2 topic list` empty (PX4 tx>0 but ROS sees nothing). The image auto-sources; only an issue in odd shells.
2. Gazebo caches models. After ANY model/airframe edit: `pkill -f 'px4|gz sim|ruby'; sleep 2` then rebuild.
3. MPC_THR_HOVER must match real hover (0.18). Stock 0.60 poisons takeoff/lineup.
4. vehicle_status -> vehicle_status_v1 (v1.16), else nodes hang "waiting to arm". (bootstrap.sh applies this.)
5. Two Pythons: venv 3.10 GPU JAX = training; system 3.12 CPU JAX + rclpy = deploy. rclpy won't load in the venv. Run the bridge WITHOUT the venv.
6. Run PS2-RL commands from ~/ws_shared/PS2-RL (that's where scripts/ and requirements.txt live).
7. Control-rate readout is wall-clock (may show 42/62 Hz). Real check: mean sim dt ~20 ms over 106 steps (span ~2.1 s).
8. origin_offset_enu: keep [0,0,0]. Nonzero z disturbed the takeoff->entry sequence even though the obs is offset-corrected.
9. Rebuild after every bridge.yaml edit (node reads install/, not source).
10. thrust_calib: 5 levels + settle 8.0, bracket hover; more levels drift and corrupt the last pulse.
11. After `docker compose down`, PX4 mods are gone (PX4 is in the image). Re-run `bash ~/ws_shared/bootstrap.sh`.

---

# GitHub update workflow

There are three separate Git repositories: `dual_stage_rl`, `PS2-RL`, and the
parent `px4-ros-docker`. Commit a submodule first, push that commit, then update
the submodule pointer in the parent. Never use `git add .` here because policy
weights and experiment outputs are large and local-only.

The parent `ws_shared/.gitignore` excludes colcon outputs, timestamped SITL
experiments, CSV logs, and generated plots. Ignore rules do not cross a
submodule boundary, so check `PS2-RL` separately:

```
cd ~/px4-ros-docker/ws_shared/PS2-RL
git check-ignore -v outputs checkpoints .venv 2>/dev/null || true
```

If `outputs/` or `checkpoints/` is not already ignored, add these entries to
the existing `PS2-RL/.gitignore` before committing source changes there:

```
/outputs/
/checkpoints/
/.venv/
**/__pycache__/
*.py[cod]
```

Do not commit `.pkl`, `.npz`, training histories, metrics, or SITL experiment
directories. Commit lightweight source/config documentation only when it is
needed for reproducibility.

### 1. Commit the bridge submodule

Run on the host:

```
cd ~/px4-ros-docker/ws_shared/dual_stage_rl
git branch --show-current
git remote -v
git status --short
git diff --check

git add \
  SITL_src/ps2rl_px4_bridge/.gitignore \
  SITL_src/ps2rl_px4_bridge/README.md \
  SITL_src/ps2rl_px4_bridge/config/bridge_x500_powerloop_delay.yaml \
  SITL_src/ps2rl_px4_bridge/ps2rl_px4_bridge/bridge_node.py \
  SITL_src/ps2rl_px4_bridge/ps2rl_px4_bridge/policy_runner.py \
  SITL_src/ps2rl_px4_bridge/run_sitl_experiment.py \
  SITL_src/ps2rl_px4_bridge/test/test_policy_runner_observation.py

git diff --cached --check
git diff --cached --stat
git commit -m "Add delay-aware SITL policy experiments"
git push origin "$(git branch --show-current)"
```

### 2. Commit PS2-RL only when its source changes are ready

The delay bridge requires the matching `use_projection` and delay-observation
support in PS2-RL. If those source changes are not already pushed, commit them
in the PS2-RL repository on a branch you control. Review `git status --short`
and stage explicit source files only; do not stage checkpoints or outputs.

After pushing, verify that the current submodule commit exists on its remote:

```
cd ~/px4-ros-docker/ws_shared/PS2-RL
git status --short
git rev-parse HEAD
git branch --show-current
git remote -v
```

If this submodule still points to a read-only upstream remote, push the source
changes to a fork first. The parent repository must not point to a commit that
other machines cannot fetch.

### 3. Commit the parent repository last

```
cd ~/px4-ros-docker
git status --short

# If generated files were committed previously, remove only their Git index
# entries. --cached leaves the local files on disk.
git rm -r --cached --ignore-unmatch \
  ws_shared/build ws_shared/install ws_shared/log ws_shared/src \
  ws_shared/experiments ws_shared/trajectory.png ws_shared/trajectory_cil.png

git add \
  ws_shared/.gitignore \
  ws_shared/PS2RL_SITL_final.md \
  ws_shared/dual_stage_rl

# Uncomment this only if a PS2-RL source commit was pushed in step 2.
# git add ws_shared/PS2-RL

git diff --cached --check
git diff --cached --stat
git diff --cached --submodule=log
git commit -m "Document organized PS2-RL SITL comparisons"
git push origin "$(git branch --show-current)"
```

On a clean machine, verify that both recorded submodule commits are fetchable:

```
git clone --recursive https://github.com/kimjw624/px4-ros-docker.git px4-ros-docker-check
cd px4-ros-docker-check
git submodule status --recursive
```

---

# Persistence summary

- Image (Dockerfile): PX4 v1.16 built from source, ROS, Gazebo, and CPU JAX (jax/jaxlib/scipy/qpax via pip --ignore-installed), plus auto-source in .bashrc.
- ws_shared (bind-mount, persistent): PS2-RL + dual_stage_rl submodules, bootstrap.sh, setup_px4_powerloop.sh, poke_test.py, thrust_fit_1kg.yaml, this md, and git-ignored experiment outputs.
- Per fresh container: `bash ~/ws_shared/bootstrap.sh` (idempotent) — applies PX4 mods, rebuilds PX4, builds the bridge.
- Editing dual_stage_rl (yours): cd into the submodule, `git checkout main` first, commit + push there, then bump the pointer in the parent repo.

# Current status

The organized SITL workflow has been verified for the vanilla nominal policy
without CIL, the vanilla delay-trained policy without CIL, and the nominal
PS2-RL policy with learned-backup CIL. The next planned run is the delay-trained
policy with CIL enabled after its training finishes. Keep vanilla-vs-vanilla
tracking comparisons separate from CIL-vs-CIL safety comparisons.
