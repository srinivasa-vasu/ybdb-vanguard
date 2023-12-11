#!/bin/bash

# set -x

# Define exercises and corresponding commands in separate arrays
exercises=("Into the distributed and postgres++ sql universe" "Query tuning tips and tricks" "Development innerloop workflow" "Java microservices" "Java testcontainers" "Securing Spring Boot Microservices" "Data migration workflow from mysql to ybdb" "Change data capture(CDC) workflow from ybdb to postgres" "Change data capture(CDC) streaming workflow from ysql to ycql" "Data distribution and scalability" "Data replication, fault tolerance and high availability")
commands=("init-dsql/.gitpod-dsql.yml" "init-qt/.gitpod-qt.yml" "init-iloop/.gitpod-iloop.yml" "" "" "" "init-voyager/.gitpod-voyager.yml" "init-cdc/.gitpod-cdc.yml" "" "init-scale/.gitpod-scale.yml" "init-ft/.gitpod-ft.yml")
links=("" "" "" "https://github.com/srinivasa-vasu/yb-ms-data" "https://github.com/srinivasa-vasu/ybdb-boot-data" "https://github.com/srinivasa-vasu/ybdb-sealed-secrets" "" "" "https://github.com/srinivasa-vasu/yb-cdc-streams" "" "")


# ANSI escape codes for colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to display the menu
menu() {
    echo -e "${YELLOW}Select an exercise:${NC}"
    for i in "${!exercises[@]}"; do
        echo -e "${GREEN}$((i+1)). ${exercises[i]}${NC}"
    done
}

# Function to execute the command based on the selected exercise
execute() {
    selected_exercise_index=$(( $1 - 1 ))
    command=${commands[$selected_exercise_index]}
    link=${links[$selected_exercise_index]}
    exercise=${exercises[$selected_exercise_index]}

    if [ -n "$command" ] || [ -n "$link" ]; then
        if [ -z "$command" ]; then
            echo -e "${GREEN}Follow the link to try this exercise: ${link}${NC}"
            exit
        fi
        echo -e "${YELLOW}Initializing the workspace for ${exercises[selected_exercise_index]}.${NC}"
        yes | cp $command .gitpod.yml
        git add .gitpod.yml
        git commit -sm "${exercise}"
        git push origin main
        echo -e "${GREEN}Workspace initialized.${NC}"
        exit
    else
        echo -e "${RED}Invalid exercise selection.${NC}"
    fi
}

# Check if the count of exercises, commands and links is the same
if [ ${#exercises[@]} -ne ${#commands[@]} ]; then
    echo -e "${RED}[Internal error]: The count of exercises and commands must be the same.${NC}"
    exit 1
fi
if [ ${#exercises[@]} -ne ${#links[@]} ]; then
    echo -e "${RED}[Internal error]: The count of exercises and links must be the same.${NC}"
    exit 1
fi

# Main script
while true; do
    menu

    read -p "Enter the number of the exercise (0 to exit): " choice

    if [ "$choice" -eq 0 ]; then
        echo -e "${YELLOW}Exiting the script. Goodbye!${NC}"
        break
    elif [ "$choice" -ge 1 ] && [ "$choice" -le ${#exercises[@]} ]; then
        execute "$choice"
    else
        echo -e "${RED}Invalid exercise selection. Please choose a valid exercise.${NC}"
    fi
done
