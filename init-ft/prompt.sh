#!/usr/bin/env bash

. pscript
set -f  # disable filename expansion — prevents SELECT * glob-expanding in eval $@

# Resolve workspace root — prompt.sh runs from init-ft/ subdirectory
WS_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "/workspaces/ybdb-vanguard")

# Resolve workspace root — prompt.sh runs from init-ft/ subdirectory
WS_ROOT=$(git rev-parse --show-toplevel 2>/dev/null || echo "/workspaces/ybdb-vanguard")

TYPE_SPEED=70

DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

MSG="Waiting for 30 seconds to see if the application is still running and the data service is still available? Check the cluster status at localhost:15433 or via 'ysqlsh / ycqlsh' shells!"

clear

PROMPT_TIMEOUT=1

p "Press enter to do chaos engineering testing!"

PROMPT_TIMEOUT=0

pe "yugabyted stop --base_dir=${WS_ROOT}/${DATA_PATH:-ybdb}/ybd6"

PROMPT_TIMEOUT=1

p "${MSG}"

PROMPT_TIMEOUT=30

p "Press enter to bring down the entire availability zone!"

PROMPT_TIMEOUT=0

pe "yugabyted stop --base_dir=${WS_ROOT}/${DATA_PATH:-ybdb}/ybd3"

PROMPT_TIMEOUT=1

p "${MSG}"

PROMPT_TIMEOUT=30

p "Press enter to bring up the instances back"

PROMPT_TIMEOUT=0

pe "yugabyted start --base_dir=${WS_ROOT}/${DATA_PATH:-ybdb}/ybd3 --advertise_address=$HOST_LB3 --join=$HOST_LB --cloud_location=ybcloud.pandora.az3 --fault_tolerance=zone --background=true"

PROMPT_TIMEOUT=1

p "${MSG}"

PROMPT_TIMEOUT=30

p "Press enter to bring up the instances back"

pe "yugabyted start --base_dir=${WS_ROOT}/${DATA_PATH:-ybdb}/ybd6 --advertise_address=$HOST_LB6 --join=$HOST_LB --cloud_location=ybcloud.pandora.az3 --fault_tolerance=zone --background=true"

PROMPT_TIMEOUT=1

p "${MSG}"

PROMPT_TIMEOUT=30

p "That's it with the chaos engineering testing!"

cmd

p ""
