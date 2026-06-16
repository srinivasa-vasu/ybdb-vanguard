#!/usr/bin/env bash

. pscript
set -f  # disable filename expansion — prevents SELECT * glob-expanding in eval $@

TYPE_SPEED=50
# Each `pe` normally pauses TWICE (before typing the command, and again before
# running it). This removes the first pause so the command types out as soon as
# you reach it; you then press Enter ONCE to run it. One pause per step.
NO_WAIT_DISPLAY_CMD=true

DEMO_PROMPT="${GREEN}➜ ${CYAN}\W ${COLOR_RESET}"

MSG="Check the load distribution at localhost:7000 or localhost:15433! Wait for a few minutes!"

clear

PROMPT_TIMEOUT=1

p "Press enter to trigger the scale out task!"

PROMPT_TIMEOUT=0

pe "yugabyted start --base_dir=${DATA_PATH}/ybd4 --advertise_address=\$HOST_LB4 --join=\$HOST_LB --cloud_location=ybcloud.pandora.az1 --fault_tolerance=zone --background=true"

PROMPT_TIMEOUT=1

p "Press enter to continue"

PROMPT_TIMEOUT=0

pe "yugabyted start --base_dir=${DATA_PATH}/ybd5 --advertise_address=\$HOST_LB5 --join=\$HOST_LB --cloud_location=ybcloud.pandora.az2 --fault_tolerance=zone --background=true"

PROMPT_TIMEOUT=1

p "Press enter to continue"

PROMPT_TIMEOUT=0

pe "yugabyted start --base_dir=${DATA_PATH}/ybd6 --advertise_address=\$HOST_LB6 --join=\$HOST_LB --cloud_location=ybcloud.pandora.az3 --fault_tolerance=zone --background=true"

PROMPT_TIMEOUT=1

p "${MSG}"

p "That's it with the scale out task!"

cmd

p ""
