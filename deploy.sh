#!/bin/sh -e

# Rquires: mkdir(1), rm(1)

################################################################################

# Usage: msg <fmt> ...
msg()
{
	local rc=$?

	local func="${FUNCNAME:-msg}"

	local fmt="${1:?missing 1st arg to ${func}() (<fmt>)}"
	shift

	[ $V -le 0 ] || printf -- "${fmt}" "$@"

	return $rc
}

# Usage: abort <fmt> ...
abort()
{
	V=1 msg "$@" >&2
	local rc=$?
	trap - EXIT
	exit $rc
}

# Usage: usage
usage()
{
	local rc=$?
	printf -- '
Usage: %s [-s <git_dir>] [-r <root_dir>] [-d <dest_dir>] [ -t <trgt_dir> ]
          [-b <ext>] [-o] [-h|-u]
where
    -s <git_dir>  - directory with project to deploy or "" (empty) to try this
                    script directory ("%s")
    -r <root_dir> - root directory to install (default: "%s")
    -d <dest_dir> - destination directory under <root_dir> where to install
                    project (default: "%s")
    -t <trgt_dir> - absolute path prefix on target system to the installed
                    files (default: "%s")
    -b <ext>      - backup existing destination regular file or symlink when
                    exists by appending .<ext>ension to entry name on rename;
                    skip on failure (default: disabled, <ext> is "%s")
    -o            - force install to skip privileged parts like user account
                    creation even if running as superuser (default: no)
    -h|-u         - display this help message

' "$prog_name" "$DFLT_SOURCE" "$DFLT_ROOT" "$DFLT_ROOT$DFLT_DEST" "$DFLT_TARGET" \
  "$BACKUP_EXT"
	exit $rc
}

# Program (script) name
prog_name="${0##*/}"

# Verbosity: log only fatal errors
[ "$V" -ge 0 -o "$V" -le 0 ] 2>/dev/null || V=0

## Parse command line and prepare environment variables

# Try to determine THIS_DIR
THIS_DIR="${0%/*}"
# Make it absolute path
THIS_DIR="$(cd "$THIS_DIR" && echo "$PWD")" &&
[ "$THIS_DIR/deploy.sh" -ef "$0" ] ||
	abort 'cannot find directory containing this script\n'

# Sane defaults
DFLT_SOURCE="${THIS_DIR}"
DFLT_ROOT='/'
DFLT_DEST=''
DFLT_TARGET="${DFLT_DEST}"

# Export variables to environment
export SOURCE="${DFLT_SOURCE}"
export ROOT="${DFLT_ROOT}"
export DEST="${DFLT_DEST}"
export TARGET=''
export BACKUP=''

BACKUP_EXT='inst-sh'
ORDINARY=''

# Parse command line options
while getopts 's:r:d:t:b:ohu' c; do
	case "$c" in
		s) SOURCE="$OPTARG" ;;
		r) ROOT="${OPTARG:?-r missing or empty argument <root_dir>}" ;;
		d) DEST="$OPTARG" ;;
		t) TARGET="$OPTARG" ;;
		b) BACKUP="${OPTARG:-$BACKUP_EXT}" ;;
		o) ORDINARY=y ;;
		h|u) usage ;;
		*) ! : || usage ;;
	esac
done
unset c

# No extra arguments
shift $((OPTIND - 1))
[ $# -eq 0 ] || usage

SOURCE="${SOURCE:-$THIS_DIR}"
INSTALL_SH="$SOURCE/install.sh"
[ -e "$SOURCE/.git" -a -e "$INSTALL_SH" ] || \
	abort '"%s" is not a <git_dir> directory\n' "$SOURCE"

if [ -n "$ORDINARY" ]; then
	# Reserved value for uid/gid is -1 as per
	# kernel/sys.c::setresuid() syscall.
	#
	# Use 0xffffffff as -1 as $(printf '%#x' -1) will
	# give 64-bit value while uid/gid are 32-bit.
	RSVD_UGID=0xffffffff

	export INSTALL_EUID=$RSVD_UGID
	export INSTALL_EGID=$RSVD_UGID
fi

export V=$V

## Install

exit_handler()
{
	local rc=$?

	set +e

	if [ $rc -eq 0 ]; then
		msg 'success\n'

		# Report install location: can be used by package manager
		local V=1
		msg 'ROOT:%s\n' "$ROOT"
	else
		msg 'failure\n'
	fi
}
trap exit_handler EXIT

msg 'installing to "%s"\n' "$ROOT"

"$INSTALL_SH"
