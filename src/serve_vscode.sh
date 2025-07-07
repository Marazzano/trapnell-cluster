#!/bin/bash
USAGE="Usage: serve_vscode [-m|--memory memory] [-c|--cores cores] [-t|--timelimit timelimit] [-r|--r_version r_version] [-p|--python_version python_version]\n\
Options:\n\
  -m, --memory     Memory to allocate for the job (default: 8G)\n\
  -c, --cores      Number of cores to allocate for the job (default: 1)\n\
  -t, --timelimit  Time limit for the job, formatted as hours:minutes:seconds (default: 48:0:0)\n\
  -r, --r_version  R version to use, formatted as 'x.x.x'. Default is to use what is in '~/.bashrc' or equivalent\n\
  -p, --python_version  Python version to use, formatted as 'x.x.x'. Default is to use what is in '~/.bashrc' or equivalent\n\
  -h, --help       Show this help message and exit\n"

# Defaults
MEM="8G"
CORES="1"
TIMELIMIT="48:0:0"

while [[ $# -gt 0 ]]; do
    case $1 in
        -m|--memory)
            MEM="$2"
            shift
            shift
            ;;
        -c|--cores)
            CORES="$2"
            shift
            shift
            ;;
        -t|--timelimit)
            TIMELIMIT="$2"
            shift
            shift
            ;;
        -r|--r_version)
            R_VERSION="$2"
            shift
            shift
            ;;
        -p|--python_version)
            PYTHON_VERSION="$2"
            shift
            shift
            ;;
        -h|--help)
            echo -e "${USAGE}"
            exit 0
            ;;
        -*|--*)
            echo "Unknown option: $1"
            echo -e "${USAGE}"
            exit 1
            ;;
        *)
            echo -e "${USAGE}"
            exit 1
            ;;
    esac
done

LOG_FILE=$HOME/nobackup/log/vscode.o
ERR_FILE=$HOME/nobackup/log/vscode.e

# Check for existing vscode tunnel jobs
existing_jobs=$(qstat -u $USER | grep "vscode" | awk '{print $1}')

# If there are existing jobs, ask if user wants to terminate them
if [ ! -z "$existing_jobs" ]; then
    job_count=$(echo "$existing_jobs" | wc -l)
    echo "Found $job_count existing VS Code tunnel job(s)"
    
    read -p "Do you want to terminate all existing VS Code tunnel jobs? [Y/n]: " terminate
    
    if [ "$terminate" = "y" ] || [ "$terminate" = "Y" ] || [ -z "$terminate" ]; then
        for job_id in $existing_jobs; do
            echo "Terminating job $job_id..."
            qdel $job_id
        done
        # Wait briefly to ensure jobs are terminated
        echo "Waiting for jobs to terminate..."
        sleep 3

    else
        echo "Keeping existing jobs. Note that multiple VS Code tunnel sessions may cause conflicts."
    fi

	echo ""
fi

if [ -f "${LOG_FILE}" ]; then
    rm "${LOG_FILE}"
fi
if [ -f "${ERR_FILE}" ]; then
    rm "${ERR_FILE}"
fi

cmd="qsub -o ${LOG_FILE} -e ${ERR_FILE} -l mfree=${MEM} -pe serial ${CORES} -l h_rt=${TIMELIMIT} -N vscode ${HOME}/sge/serve_vscode.sge"

# Add R and Python versions to the command if specified
if [ -n "${R_VERSION}" ]; then
    cmd+=" -r ${R_VERSION}"
fi
if [ -n "${PYTHON_VERSION}" ]; then
    cmd+=" -p ${PYTHON_VERSION}"
fi

echo -e "Submitting a VSCode server with the command:\n\t${cmd}\n\n"

# IMPROVED: Capture both output and exit code
submission_output=$(eval "${cmd}" 2>&1)
exit_code=$?

# Check if submission was successful
if [ $exit_code -ne 0 ]; then
    echo "❌ ERROR: Job submission failed!"
    echo "Exit code: $exit_code"
    echo "Output: $submission_output"
    
    # Check for common error patterns
    if echo "$submission_output" | grep -q "modified hard resource list of job 0"; then
        echo ""
        echo "💡 SUGGESTION: Resource allocation issue detected."
        echo "   Try reducing memory request: serve_vscode -m 16G (current: ${MEM})"
        echo "   Or reduce cores: serve_vscode -c 1 (current: ${CORES})"
        echo "   Or reduce time limit: serve_vscode -t 24:0:0 (current: ${TIMELIMIT})"
    elif echo "$submission_output" | grep -q "could not be scheduled"; then
        echo ""
        echo "💡 SUGGESTION: Queue is full or resources unavailable."
        echo "   Try again later or reduce resource requirements."
        echo "   Check queue status with: qstat -g c"
    elif echo "$submission_output" | grep -q "Unknown option\|error:"; then
        echo ""
        echo "💡 SUGGESTION: Command syntax error."
        echo "   Check your qsub parameters and SGE configuration."
    fi
    
    exit 1
fi

# Extract job ID from successful submission
job_id=$(echo "$submission_output" | grep -o "Your job [0-9]*" | grep -o "[0-9]*")

if [ -n "$job_id" ]; then
    echo "✅ Job submitted successfully with ID: $job_id"
else
    echo "⚠️  Job submitted but could not extract job ID from output:"
    echo "$submission_output"
fi

WAIT_TIME=5
echo "Waiting for ${WAIT_TIME} seconds for the job to start..."
sleep ${WAIT_TIME}

# IMPROVED: Check job status before looking for log file
if [ -n "$job_id" ]; then
    job_status=$(qstat -j $job_id 2>/dev/null | grep "job_state" | awk '{print $2}')
    
    if [ -z "$job_status" ]; then
        echo "⚠️  Job $job_id is no longer in queue (may have finished quickly or failed)"
    elif [ "$job_status" = "qw" ]; then
        echo "⏳ Job $job_id is still waiting in queue..."
        echo "   You can check status with: qstat -u $USER"
        echo "   If job stays queued, try reducing resource requirements."
    elif [ "$job_status" = "r" ]; then
        echo "🚀 Job $job_id is running!"
    else
        echo "📊 Job $job_id status: $job_status"
    fi
fi

# Check if the log file exists
if [ -f "${LOG_FILE}" ]; then
    # Wait for the GitHub login line to appear (try for up to 10 seconds)
    echo "Looking for GitHub login information..."
    max_attempts=30
    attempts=0
    
    AUTH_MSG=""
    while [ $attempts -lt $max_attempts ]; do
        # Check if the GitHub login line exists in the log file
        if grep -q "Found token in keyring" "${LOG_FILE}"; then
            AUTH_MSG="Server is already authenticated. Open VS Code, select 'Connect to Tunnel...' and then 'GitHub' to connect to the server."
            break
        elif grep -q "To grant access to the server, please log into" "${LOG_FILE}"; then
            # Extract and display the line containing the GitHub login URL and code
            github_line=$(grep "To grant access to the server, please log into" "${LOG_FILE}")
            AUTH_MSG="\n-------------------------------------------------------\n$github_line\n-------------------------------------------------------\n\nAfter authenticating, open VS Code, select 'Connect to Tunnel...' and then 'GitHub' to connect to the server."
            break
        fi
        # Increment attempts counter
        attempts=$((attempts + 1))
        # Wait for 1 second before checking again
        sleep 1
    done
    
    # If we couldn't find the line after all attempts
    if [ $attempts -eq $max_attempts ]; then
        AUTH_MSG="Could not find GitHub login information after ${max_attempts} seconds.\nPlease check the log file manually at: ${LOG_FILE}"
        
        # Check error file for issues
        if [ -f "${ERR_FILE}" ] && [ -s "${ERR_FILE}" ]; then
            echo ""
            echo "⚠️  Errors detected in: ${ERR_FILE}"
            echo "Recent errors:"
            tail -5 "${ERR_FILE}"
        fi
    fi
else
    echo "❌ Log file not found at ${LOG_FILE} after waiting ${WAIT_TIME} seconds."
    
    if [ -n "$job_id" ]; then
        # Check if job is still in queue
        if qstat -j $job_id >/dev/null 2>&1; then
            echo "Job $job_id is still in queue. Status:"
            qstat -u $USER | grep $job_id
        else
            echo "Job $job_id has completed or failed."
            if [ -f "${ERR_FILE}" ] && [ -s "${ERR_FILE}" ]; then
                echo "Check error file: ${ERR_FILE}"
                echo "Recent errors:"
                tail -10 "${ERR_FILE}"
            fi
        fi
    fi
    
    echo ""
    echo "💡 Troubleshooting suggestions:"
    echo "   1. Check job status: qstat -u $USER"
    echo "   2. Check queue availability: qstat -g c" 
    echo "   3. Try with lower resources: serve_vscode -m 8G -c 1"
    echo "   4. Check error log: ${ERR_FILE}"
    
    exit 1
fi

sleep 1

# Check for errors loading modules
module_errors=$(grep "ERROR: Unable to locate a modulefile for" ~/nobackup/log/vscode.e 2>/dev/null)
if [ -n "$module_errors" ]; then
    echo "Error loading modules. Check your module versions are valid. Error message:"
    echo "$module_errors"
    exit 1
fi

# Display the authentication message
echo -e "$AUTH_MSG"
