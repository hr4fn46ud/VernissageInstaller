#!/bin/sh

set -eu

executable_path="${1:-.build/debug/vernissagectl}"

[ -x "$executable_path" ] || {
    printf 'Executable not found: %s\n' "$executable_path" >&2
    exit 1
}

version_output="$("$executable_path" --version)"
help_output="$("$executable_path" --help)"
ready_output="$("$executable_path")"
doctor_help_output="$("$executable_path" doctor --help)"
install_help_output="$("$executable_path" install --help)"
logs_help_output="$("$executable_path" logs --help)"
outdated_help_output="$("$executable_path" outdated --help)"
restart_help_output="$("$executable_path" restart --help)"
services_help_output="$("$executable_path" services --help)"
start_help_output="$("$executable_path" start --help)"
status_help_output="$("$executable_path" status --help)"
stop_help_output="$("$executable_path" stop --help)"
update_help_output="$("$executable_path" update --help)"

printf '%s\n' "$version_output" | grep -Eq '^vernissagectl [0-9]+\.[0-9]+\.[0-9]+$'
printf '%s\n' "$help_output" | grep -Fq 'USAGE: vernissagectl'
printf '%s\n' "$help_output" | grep -Fq -- '--config'
printf '%s\n' "$ready_output" | grep -Fq 'The Vernissage installer is ready.'
printf '%s\n' "$doctor_help_output" | grep -Fq 'USAGE: vernissagectl doctor'
printf '%s\n' "$doctor_help_output" | grep -Fq -- '--full'
printf '%s\n' "$install_help_output" | grep -Fq -- '--domain'
printf '%s\n' "$install_help_output" | grep -Fq -- '--admin-email'
printf '%s\n' "$install_help_output" | grep -Fq -- '--admin-username'
printf '%s\n' "$install_help_output" | grep -Fq -- '--images-url'
printf '%s\n' "$logs_help_output" | grep -Fq 'USAGE: vernissagectl logs'
printf '%s\n' "$logs_help_output" | grep -Fq -- '--follow'
printf '%s\n' "$outdated_help_output" | grep -Fq 'vernissagectl outdated'
printf '%s\n' "$outdated_help_output" | grep -Fq -- '--config'
printf '%s\n' "$restart_help_output" | grep -Fq 'USAGE: vernissagectl restart'
printf '%s\n' "$restart_help_output" | grep -Fq '<service>'
printf '%s\n' "$services_help_output" | grep -Fq 'vernissagectl services'
printf '%s\n' "$services_help_output" | grep -Fq -- '--config'
printf '%s\n' "$start_help_output" | grep -Fq 'USAGE: vernissagectl start'
printf '%s\n' "$start_help_output" | grep -Fq '<service>'
printf '%s\n' "$status_help_output" | grep -Fq 'vernissagectl status'
printf '%s\n' "$status_help_output" | grep -Fq -- '--config'
printf '%s\n' "$stop_help_output" | grep -Fq 'USAGE: vernissagectl stop'
printf '%s\n' "$stop_help_output" | grep -Fq '<service>'
printf '%s\n' "$update_help_output" | grep -Fq 'USAGE: vernissagectl update'
printf '%s\n' "$update_help_output" | grep -Fq '<component>'
printf '%s\n' "$update_help_output" | grep -Fq 'all'

printf 'Smoke tests passed for %s\n' "$executable_path"
