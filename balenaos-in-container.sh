#!/bin/bash

set -e

config_path=""
docker_prefix="balena-"
docker_postfix="$RANDOM"
clean_volumes=no
docker_extra_args=""
detach=""
no_tty="-ti"

function help {
	cat << EOF
Run balenaOS image in a docker container.
$0 <ARGUMENTS>

ARGUMENTS:
	-h, --help
		Print this message.
	--image <image>
		Docker image to be used as balenaOS.
		Mandatory argument.
	--prefix <prefix>
		Use a specific prefix for the docker container and volumes. This allows for
		reusing volumes.
		Default: "balena-"
	--id <id>
		Use a specific id for the docker container and volumes. This allows for
		reusing volumes.
		Default: randomly generated.
	-c, --config <config>
		The config.json path. This you can download from balena.io dashboard.
		Mandatory argument.
	-d, --detach
		Run the container in the background and print container ID (just like "docker run -d")
		Default: no.
	--extra-args <arguments>
		Additional arguments for docker run (e.g. to add bind mounts)
	--clean-volumes
		If volumes are not planned to be reused, you can take advantage of this
		argument to clean up the system. Cannot be used together with -d.
		Default: no.
	--no-tty
		Don't allocate a pseudo-TTY and don't keep STDIN open (docker run without "-it").
		Default: no.
EOF
}

# realpath is not available on Mac OS, define it as a bash function if it's not found
command -v realpath >/dev/null 2>&1 || {
    realpath() {
        [[ $1 = /* ]] && echo "$1" || echo "$PWD/${1#./}"
    }
}

# Parse arguments
while [[ $# -ge 1 ]]; do
	i="$1"
	case $i in
		-h|--help)
			help
			exit 0
			;;
		--image)
			if [ -z "$2" ]; then
				log ERROR "\"$1\" argument needs a value."
			fi
			image="$2"
			shift
			;;
		--prefix)
			if [ -z "$2" ]; then
				log ERROR "\"$1\" argument needs a value."
			fi
			docker_prefix="$2"
			shift
			;;
		--id)
			if [ -z "$2" ]; then
				log ERROR "\"$1\" argument needs a value."
			fi
			docker_postfix="$2"
			shift
			;;
		-c|--config)
			config_json="$(realpath "$2")"
			if [ ! -f "$config_json" ]; then
				echo "ERROR: $config_path no such file."
				exit 1
			fi
			shift
			;;
		-d|--detach)
			detach="--detach"
			;;
		--extra-args)
			docker_extra_args="$2"
			shift
			;;
		--clean-volumes)
			clean_volumes=yes
			;;
		--no-tty)
			no_tty=""
			;;
		*)
			echo "ERROR: Unrecognized option $1."
			help
			exit 1
			;;
	esac
	shift
done

if [ -z "$image" ] || [ -z "$config_json" ]; then
	echo "ERROR: Required arguments not provided."
	help
	exit 1
fi

if ! docker info &> /dev/null; then
    echo "ERROR: Docker needs to be running on your host machine."
    exit 1
fi

# Get absolute path of the script location
# In this way we can reference any file relative to the script path easily
# Get the absolute script location
SCRIPTPATH="$(cd "$(dirname "$0")" ; pwd)"

for volume in boot state data; do
	if docker volume inspect "${docker_prefix}${volume}-${docker_postfix}" &> /dev/null; then
		echo "INFO: Reusing ${docker_prefix}${volume}-${docker_postfix} docker volume..."
	else
		echo "INFO: Creating ${docker_prefix}${volume}-${docker_postfix} docker volume..."
		docker volume create "${docker_prefix}${volume}-${docker_postfix}" &> /dev/null
	fi
done
balena_boot_volume="${docker_prefix}boot-${docker_postfix}:/mnt/boot"
balena_state_volume="${docker_prefix}state-${docker_postfix}:/mnt/state"
balena_data_volume="${docker_prefix}data-${docker_postfix}:/mnt/data"

# Populate the boot volume with the config.json
docker run -i --rm -v \
	"$balena_boot_volume" -v "$config_json":/config.json \
	"$image" sh << EOF
if ! [ -f /mnt/boot/config.json ]; then
	cp /config.json /mnt/boot/config.json
else
	echo "INFO: Reusing already existing config.json in docker volume."
fi
EOF

container_name="${docker_prefix}container-${docker_postfix}"
echo "INFO: Running balenaOS as container ${container_name} ..."
#shellcheck disable=SC2086
if docker run $no_tty --rm --privileged \
		-e "container=docker" \
		--stop-timeout=30 \
		--dns 127.0.0.2 \
		--name "${container_name}" \
		--stop-signal SIGRTMIN+3 \
		-v /lib/modules:/lib/modules:ro \
		-v "$SCRIPTPATH/conf/systemd-watchdog.conf:/etc/systemd/system.conf.d/watchdog.conf:ro" \
		-v "$balena_boot_volume" \
		-v "$balena_state_volume" \
		-v "$balena_data_volume" \
		$docker_extra_args \
		$detach \
		"$image" \
		/sbin/init; then
	if [ "$detach" != "" ]; then
		echo "INFO: balenaOS container running as ${container_name}"
	else
		echo "ERROR: Running docker container."
	fi
else
	if [ "$detach" != "" ]; then
		echo "ERROR: Running docker container."
	else
		echo "INFO: balenaOS container stopped."
	fi
fi

if [ "$detach" = "" ] && [ "$clean_volumes" = "yes" ]; then
	echo "Cleaning volumes..."
	docker volume rm "${docker_prefix}boot-${docker_postfix}" "${docker_prefix}state-${docker_postfix}" "${docker_prefix}data-${docker_postfix}" &> /dev/null
fi
