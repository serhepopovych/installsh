#!/bin/sh -e

# Requires: id(1), mkdir(1), ln(1), cp(1), mv(1), rm(1), readlink(1), sed(1)
# Requires: chown(1), chmod(1), cmp(1), mktemp(1), sort(1), tr(1), rmdir(1)

# Usage: pass() [...]
pass()
{
	:
}

# Usage: fail() [...]
fail()
{
	! :
}

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

# Usage: log <fmt> ...
log()
{
	local rc=$?

	local func="${FUNCNAME:-log}"

	local fmt="${1:?missing 1st arg to ${func}() (<fmt>)}"
	shift
	local verdict

	if [ -z "$LOG_MSG" ]; then
		[ $rc -eq 0 ] && verdict='success' || verdict='failure'
	else
		verdict=''
	fi

	[ ${#L} -ne 1 ] || eval printf ${INSTALL_LOG:+>>"'$INSTALL_LOG'"} -- \
		"'%s: %s: ${fmt}%s'" "'${NAME:-unknown}'" "'$L'" '"$@"' \
		"'${verdict:+: $verdict
}'"
	return $rc
}

# Usage: log_msg <fmt> ...
log_msg()
{
	local func="${FUNCNAME:-log_msg}"
	local LOG_MSG="${func}"

	log "$@"
}

# Usage: return_var() <rc> [<result> [<var>]]
return_var()
{
	local func="${FUNCNAME:-return_var}"

	local rv_rc="${1:?missing 1st arg to ${func}() (<rc>)}"
	local rv_result="$2"
	local rv_var="$3"

	if [ -n "${rv_result}" ]; then
		if [ -n "${rv_var}" ]; then
			eval "${rv_var}='${rv_result}'"
		else
			echo "${rv_result}"
		fi
	fi

	return ${rv_rc}
}

# Usage: normalize_path() <path> [<var_result>]
normalize_path()
{
	local func="${FUNCNAME:-normalize_path}"

	local path="${1:?missing 1st arg to ${func}() (<path>)}"
	local file=''

	if [ ! -d "${path}" ]; then
		file="${path##*/}"
		[ -n "$file" ] || return
		path="${path%/*}"
		[ -d "$path" ] || return
	fi

	cd "${path}" && path="${PWD}${file:+/$file}" && cd - >/dev/null
	return_var $? "$path" "$2"
}

# Usage: relative_path <src> <dst> [<var_result>]
relative_path()
{
	local func="${FUNCNAME:-relative_path}"

	local rp_src="${1:?missing 1st arg to ${func}() (<src>)}"
	local rp_dst="${2:?missing 2d arg to ${func}() (<dst>)}"

	# add last component from src if dst ends with '/'
	[ -n "${rp_dst##*/}" ] || rp_dst="${rp_dst}${rp_src##*/}"

	# normalize pathes first
	normalize_path "${rp_src}" rp_src || return
	normalize_path "${rp_dst}" rp_dst || return

	# strip leading and add trailing '/'
	rp_src="${rp_src#/}/"
	rp_dst="${rp_dst#/}/"

	while :; do
		[ "${rp_src%%/*}" = "${rp_dst%%/*}" ] || break

		rp_src="${rp_src#*/}" && [ -n "${rp_src}" ] || return
		rp_dst="${rp_dst#*/}" && [ -n "${rp_dst}" ] || return
	done

	# strip trailing '/'
	rp_dst="${rp_dst%/}"
	rp_src="${rp_src%/}"

	# add leading '/' for dst only: for src we will add with sed(1) ../
	rp_dst="/${rp_dst}"

	# add leading '/' to dst, replace (/[^/])+ with ../
	rp_dst="$(echo "${rp_dst%/*}" | \
		  sed -e 's|\(/[^/]\+\)|../|g')${rp_src}" || \
		return

	return_var 0 "${rp_dst}" "$3"
}

# Usage: subpath <prefix> <path> [<var_result>]
subpath()
{
	local func="${FUNCNAME:-subpath}"

	local prefix="${1:?missing 1st arg to ${func}() (<prefix>)}"
	local path="${2:?missing 2d arg to ${func}() (<path>)}"
	local p

	p="${p%.}"
	p="${path%%/}"
	# Terminate path with single '/' even if it is a file.
	p="$p/"

	prefix="${prefix%.}"
	prefix="${prefix%%/}"

	# Outside of prefix directory?
	[ -z "${p##$prefix/*}" ] || return

	return_var 0 "${path#$prefix}" "$3"
}

# Usage: same <s> <d>
same()
{
	local func="${FUNCNAME:-same}"

	local s="${1:?missing 1st arg to ${func}() (<s>)}"
	local d="${2:?missing 2d arg to ${func}() (<d>)}"

	# Device and inode number are the same?
	if [ "$d" -ef "$s" ]; then
		return 0
	fi
	# Symlinks and target is the same?
	if [ -L "$d" -a -L "$s" -a \
	     "$(readlink -q "$d")" = "$(readlink -q "$s")" ]; then
		return 0
	fi
	# Not a directory and content is the same?
	if [ ! -d "$d" -a ! -d "$s" ] && cmp -s "$d" "$s"; then
		return 0
	fi
	return 1
}

# Following environment variables can override install_sh() functionality:
#  SP     - source prefix set from <src_prefix> by initial install_sh() call
#  DP     - destination prefix set from <dst_prefix> by inital install_sh() call
#  MKDIR  - create destination directories (default: install -d), use /bin/false
#           to force destination directory tree to exist and match source
#  BACKUP - backup file extension or empty to disable backups (default: empty)
#  EEXIST - fail when non-empty, destination file exists and backup either
#           disabled or failed (default: empty)
#  CP_OPTS - additional cp(1) options (default: --remove-destination when
#            BACKUP is empty and '-S".$BACKUP" -b' when set)
#  REG_FILE_COPY - copy regular file (default: install_sh__reg_file_copy())
#  SCL_FILE_COPY - copy special file like device or socket
#                  (default: install_sh__scl_file_copy())

# Usage: install_sh__backup() <dst> [<tgt>]
install_sh__backup()
{
	local func="${FUNCNAME:-install_sh__backup}"

	local d="${1:?missing 1st arg to ${func}() (<dst>)}"
	local t="$2"

	[ -z "$t" ] || ! same "$d" "$t" || return 0

	local rc=0

	if [ -L "$d" ]; then
		# cp(1) does follow link for existing
		# directories even with -d option
		if [ -n "$BACKUP" ]; then
			mv -f "$d" "$d.$BACKUP" || rc=$?
		else
			rm -f "$d" || rc=$?
		fi
		[ $rc -eq 0 -o -z "$EEXIST" ] || return $rc
	elif [ -d "$d" ]; then
		rmdir "$d" 2>/dev/null || return
	fi

	# Not copying to directory
	[ ! -d "$d" ]
}

# Usage: install_sh__reg_file_copy() <src> <dst>
install_sh__reg_file_copy()
{
	local func="${FUNCNAME:-install_sh__reg_file_copy}"

	local s="${1:?missing 1st arg to ${func}() (<src>)}"
	local d="${2:?missing 2d arg to ${func}() (<dst>)}"

	if [ -L "$s" ]; then
		t="$(cd "$SP" && readlink -m "$s")" || return
		# Outside of SP directory?
		subpath "$SP" "$t" t || return
		# Make path relative
		t="$DP$t"
		[ -e "$t" -o ! -d "$s" ] || mkdir -p "$t" || return
		relative_path "$t" "$d" s || return
		# Backup if needed before installing
		install_sh__backup "$d" "$t" || return
		# Link it
		ln -snf "$s" "$d" || return
	else
		# Backup if needed before installing
		install_sh__backup "$d" || return
		# Copy regular file
		cp -fd $CP_OPTS "$s" "$d" || return
	fi
}

# Usage: install_sh__scl_file_copy() <src> <dst>
install_sh__scl_file_copy()
{
	local func="${FUNCNAME:-install_sh__scl_file_copy}"

	local s="${1:?missing 1st arg to ${func}() (<src>)}"
	local d="${2:?missing 2d arg to ${func}() (<dst>)}"

	# Not backing up specific files
	[ ! -d "$d" -o -L "$d" ] || rmdir "$d" 2>/dev/null || return
	ln -snf "$s" "$d"
}

# Usage: install_sh() <src_prefix> <dst_prefix> [files and/or dirs...]
install_sh()
{
	local func="${FUNCNAME:-install_sh}"

	local sp="${1:?missing 1st arg to ${func}() (<src_prefix>)}"
	local dp="${2:?missing 2d arg to ${func}() (<dst_prefix>)}"
	shift 2

	if [ -z "$SP" ]; then
		# These variables are set once on initial install_sh()
		# call and can change behaviour of function
		local SP="$sp"
		local DP="$dp"

		local MKDIR="${MKDIR:-mkdir -p}"

		local BACKUP="${BACKUP:-}"
		local EEXIST="${EEXIST:-}"

		local REG_FILE_COPY="${REG_FILE_COPY:-install_sh__reg_file_copy}"
		local SCL_FILE_COPY="${SCL_FILE_COPY:-install_sh__scl_file_copy}"

		# These are set once too but their value depends
		# on above variables
		local CP_OPTS_BACKUP="-S.${BACKUP:-inst-sh} -b"
		local CP_OPTS_NORMAL='--remove-destination'
		local CP_OPTS
		CP_OPTS="${BACKUP:+$CP_OPTS_BACKUP}"
		CP_OPTS="${CP_OPTS:-$CP_OPTS_NORMAL}"
	fi

	while [ $# -gt 1 ]; do
		[ -z "$1" ] || "${func}" "$sp" "$dp" "$1" || return
		shift
	done

	local fd="${1##/}"
	[ -n "$fd" ] || return 0

	local src="$sp/$fd"
	[ -e "$src" ] || return 0
	src="${src%%/}"
	local dst="$dp/$fd"

	local s d

	[ -L "$src" -o ! -d "$src" ] || src="$src/* $src/.*"

	d="$dst"
	if [ ! -e "$d" ]; then
		# Non-existing file?
		if [ -n "${d##*/}" ]; then
			d="${d%/*}"
			[ ! -e "$d" ] || d=
		fi
		if [ -n "$d" ]; then
			$MKDIR "$d" || return
		fi
	fi

	for s in $src; do
		# Skip special directories
		src="${s##*/}"
		[ "$src" != '.' -a "$src" != '..' ] || continue

		# Directories are first
		if [ ! -L "$s" -a -d "$s" ]; then
			"${func}" "$sp" "$dp" "${s#$sp/}/" || return
			continue
		fi

		# If $src is empty directory wildcard does not expand
		[ -e "$s" ] || continue

		# Add last component of source name to $d if it is directory
		d="$dst"
		if [ ! -L "$d" -a -d "$d" ]; then
			d="$d/${s##*/}"
		fi

		# Skip if destination exists and same as source
		if [ -e "$d" -o -L "$d" ]; then
			! same "$s" "$d" || continue
			[ -n "$BACKUP" -o -z "$EEXIST" ] || return
		fi

		# Symlinks, files and specials are next
		if [ -L "$s" -o -f "$s" ]; then
			$REG_FILE_COPY "$s" "$d" || return
		elif [ -e "$s" ]; then
			$SCL_FILE_COPY "$s" "$d" || return
		fi
	done
}

# Usage walk_paths() <action> [<path>...]
walk_paths()
{
	local func="${FUNCNAME:-walk_paths}"

	local action="${1:?missing 1st arg to ${func}() (<action>)}"
	shift

	while [ $# -gt 1 ]; do
		[ -z "$1" ] || "${func}" "$action" "$1" || return
		shift
	done

	local path="$1"
	[ -n "$path" ] || return 0

	[ ! -L "$path" ] || return 0
	[ ! -d "$path" ] || path="$path/* $path/.*"

	for p in $path; do
		# Skip special directories
		path="${p##*/}"
		[ "$path" != '.' -a "$path" != '..' ] || continue

		# Skip symlinks as they might point outside of tree
		[ ! -L "$p" ] || continue

		# Handle nested directories
		if [ -d "$p" ]; then
			"${func}" "$action" "$p" || return
			continue
		fi

		# If $src is empty directory wildcard does not expand
		[ -e "$p" ] || continue

		# Execute specific action for given path
		"$action" "$p" || return
	done
}

# Usage: exec_vars() [NAME=VAL...] [--] <command> [<args>...]
exec_vars()
{
	local func="${FUNCNAME:-exec_vars}"

	# Bash and dash behaves differently when calling
	# with variable preset: use function with local
	# variables to handle both.
	while [ $# -gt 0 ]; do
		case "$1" in
			*=*)  eval "local '$1'; export '${1%%=*}'" ;;
			--)   shift; break ;;
			*)    break ;;
		esac
		shift
	done

	eval "$@"
}

# Usage: inherit() <subproject>/<path_to_file>
inherit()
{
	local func="${FUNCNAME:-inherit}"

	local f="${1:?missing 1st arg to ${func}() (<subproject>/<path_to_file>)}"
	local sp="$SOURCE/.subprojects/${f%%/*}"
	f="${f#*/}"

	[ ! -f "$sp/$f" ] || exec_vars SOURCE="$sp" -- . "\$SOURCE/$f"
}

# Usage: subst_templates_sed <file>
subst_templates_sed()
{
	local f="$1"

	[ -f "$f" -a -s "$f" ] || return 0

	eval sed -i "\$f" $SUBST_TEMPLATES
}

# Register default hook. Can be overwritten in "vars-sh".
subst_templates_hook=''

# Usage: subst_templates <file>
subst_templates_typecheck_done=''
subst_templates()
{
	local func="${FUNCNAME:-subst_templates}"

	local rc

	# Typecheck registered hook
	if [ -z "$subst_templates_typecheck_done" ]; then
		if [ -n "$subst_templates_hook" ]; then
			rc="$(type "$subst_templates_hook" 2>/dev/null)"
			[ -z "${rc##*function*}" ] ||
				subst_templates_hook='subst_templates_sed'
		else
			subst_templates_hook='subst_templates_sed'
		fi
		subst_templates_typecheck_done=y
	fi

	local __ifs="${IFS}"
	IFS='
'
	"$subst_templates_hook" "$1"
	rc=$?
	IFS="${__ifs}"

	return_var $rc

	log 'replaced templates in "%s" file' "${1#$DEST/}"
}

# Usage: reg_file_copy()
reg_file_copy()
{
	local func="${FUNCNAME:-reg_file_copy}"

	local s="${1:?missing 1st arg to ${func}() (<src>)}"
	local d="${2:?missing 2d arg to ${func}() (<dst>)}"
	local t

	if [ -L "$s" ]; then
		t="$(cd "$SP" && readlink -m "$s")" || return
		# Outside of SP directory?
		subpath "$SP" "$t" t || return
		# Subproject responsibility?
		[ -n "${t##*/.subprojects/*}" ] || return 0
		# Make path relative: we do not expect symlinks from DEST
		# to ROOT as pointless and DEST installed before ROOT
		t="$(cd "$DP" && readlink -m "$DP$t")" || return
		# Outside of DP directory?
		subpath "$DP" "$t" t || return
		t="$DP$t"
		[ -e "$t" -o ! -d "$s" ] || mkdir -p "$t" || return
		relative_path "$t" "$d" s || return
		# Backup if needed before installing
		install_sh__backup "$d" "$t" || return
		# Link it
		ln -snf "$s" "$d" || return
	else
		if [ -n "$DO_SUBST_TEMPLATES" ]; then
			# Copy source to temporary destination
			t="$(mktemp "$d.XXXXXXXX")" && cp -fd "$s" "$t" &&
				exec_vars L='' -- subst_templates "'$t'" || return

			if [ -d "$d" ] || ! cmp -s "$t" "$d"; then
				# Backup if needed before installing
				install_sh__backup "$d" || return
				# Hard link temporary file
				cp -fd $CP_OPTS -l "$t" "$d" &&
					chmod -f --reference="$s" "$d" || return
			fi
			rm -f "$t" || return
		else
			# Backup if needed before installing
			install_sh__backup "$d" || return
			# Copy regular file
			cp -fd $CP_OPTS "$s" "$d" || return
		fi
	fi

	log 'installed "%s" to "%s"' "${d#$TRGT/}" "$TRGT"
}

# Usage: install_root() [<file|dir>...]
install_root()
{
	local REG_FILE_COPY='reg_file_copy'
	local L='R'
	local TRGT="$ROOT"
	local DO_SUBST_TEMPLATES=y

	install_sh "$SOURCE" "$TRGT" "$@"

	# End: remove compatibility sumlinks to DEST from ROOT
	if [ -n "$RD" ]; then
		local l lnk
		for l in "$ROOT"/* "$ROOT"/.*; do
			# Is it symlink?
			[ -L "$l" ] || continue

			# Is it's target is RD?
			lnk="$(readlink -q "$l")"
			[ -z "${lnk##$RD/*}" ] || continue

			# Then remove it
			rm -f "$l" ||:
		done
	fi
}

# Usage: install_dest() [<file|dir>...]
install_dest()
{
	local REG_FILE_COPY='reg_file_copy'
	local L='D'
	local TRGT="$DEST"
	local DO_SUBST_TEMPLATES=y

	install_sh "$SOURCE" "$TRGT" "$@"

	# Begin: create symlinks to DEST entries in ROOT
	if [ -n "$RD" ]; then
		local TP
		while [ $# -gt 0 ]; do
			TP="$ROOT/$1"
			[ -e "$TP" ] || ln -snf "$RD/${1##/}" "$TP" || return
			shift
		done
	fi
}

# Usage: adj_rights() <owner> <mode> ...
adj_rights()
{
	local func="${FUNCNAME:-adj_rights}"

	local owner="$1"
	local mode="$2"
	shift 2
	local L='O'

	[ "$owner" != ':' ] || owner=''

	while [ $# -gt 0 ]; do
		[ -z "$owner" ] || chown "$owner" "$1" || return
		[ -z "$mode" ] || chmod "$mode"  "$1" || return

		log 'adjusted rights on "%s": owner(%s), mode(%s)' \
			"${1#$DEST/}" \
			"${owner:-not changed}" "${mode:-not changed}"
		shift
	done
}

# Usage: begin_header <file>
begin_header()
{
	local func="${FUNCNAME:-begin_header}"

	local f="${1:?missing 1st arg to ${func}() (<file>)}"

	echo "$begin_header_str" >>"$f"
}

# Usage: end_header <file>
end_header()
{
	local func="${FUNCNAME:-end_header}"

	local f="${1:?missing 1st arg to ${func}() (<file>)}"

	echo "$end_header_str" >>"$f"
}

# Usage: prepare_file <file>
prepare_file()
{
	local func="${FUNCNAME:-prepare_file}"

	local f="${1:?missing 1st arg to ${func}() (<file>)}"

	if [ -e "$f" ]; then
		# Remove block wrapped by begin/end header
		[ -f "$f" ] || return
		sed -n -e "/$begin_header_str/,/$end_header_str/!p" -i "$f" ||:
	else
		# Make sure we are not ending with '/'
		[ -n "${f##*/}" ] || return

		local d="$ROOT/${f%/*}"
		if [ ! -d "$d" ]; then
			[ ! -e "$d" ] && mkdir -p "$d" || return
		fi

		# Create empty file
		: >"$f" || return
	fi
}

################################################################################

# Program (script) name
prog_name="${0##*/}"

# Verbosity: report errors by default
[ "$V" -le 0 -o "$V" -ge 0 ] 2>/dev/null || V=1

# Logging facility: G - Global
L='G'

# Try to determine SOURCE
SOURCE="${0%/*}"
# Make it absolute path
SOURCE="$(cd "$SOURCE" && echo "$PWD")" &&
[ "$SOURCE/install.sh" -ef "$0" -a -f "$SOURCE/vars-sh" ] ||
	abort '%s: cannot find project location\n' "$prog_name"
NAME="${SOURCE##*/}"
NAME_UC="$(echo "$NAME" | tr '[:lower:]' '[:upper:]')"

# Prepare begin/end header strings
begin_header_str="##### BEGIN ${NAME_UC} #####"
end_header_str="##### END ${NAME_UC} #####"

# Detect if running as base
[ ! -L "$SOURCE/install.sh" ] &&
	AS_BASE="$NAME" || AS_BASE=

if [ -z "$PARENT" ]; then
	# System wide directory prefix
	ROOT="${ROOT%%/}"
	if [ -n "$ROOT" ]; then
		# If not absolute path, assume current directory
		[ -z "${ROOT##/*}" ] || ROOT="./$ROOT"

		# If ROOT is a (symlink to) directory; does not exist or broken
		# symlink that successfuly removed and mkdir(1) succeeded: continue
		if [ -d "$ROOT" ] || {
			[ ! -e "$ROOT" ] &&
			{ [ ! -L "$ROOT" ] || rm -f "$ROOT"; } &&
			mkdir -p "$ROOT"
		}; then
			:
		else
			abort '%s: ROOT="%s" exists and not a directory: aborting\n' \
				"$prog_name" "$ROOT"
		fi

		ROOT="$(cd "$ROOT" && echo "$PWD")" ||
			abort '%s: ROOT="%s" cannot make absolute path\n' \
				"$prog_name" "$ROOT"
	else
		ROOT='/'
	fi
	export ROOT

	# Make sure DEST is subpath under ROOT
	DEST="${DEST%.}"
	DEST="${DEST%%/}"
	if [ -n "$DEST" ]; then
		# If not absolute path: make it relative to root
		if [ -z "${DEST##/*}" ]; then
			subpath "$ROOT" "$DEST" DEST ||
			abort '%s: DEST="%s" is not subpath of ROOT="%s": aborting\n' \
				"$prog_name" "$DEST" "$ROOT"
		else
			DEST="/$DEST"
		fi
	fi
	export RD="${DEST##/}"
	export DEST="$ROOT$DEST"

	# Destination on target system (useful for package build)
	export TARGET="${TARGET:-$DEST}"

	# Working directory
	export WORK_DIR="$DEST/.install"
	# Create installation log
	export INSTALL_LOG="$WORK_DIR/install.log"

	# Initialize install
	rm -rf "$WORK_DIR" ||:
	mkdir -p "$WORK_DIR" ||
		abort '%s: cannot create work directory "%s"\n' \
			"$prog_name" "$WORK_DIR"

	: >"$INSTALL_LOG" ||
		abort '%s: log file "%s" is not writable\n' \
			"$prog_name" "$INSTALL_LOG"
fi

# Make sure we run once per subproject
MARK_FILE="$WORK_DIR/do-$NAME"

if [ -e "$MARK_FILE" ]; then
	exec_vars L='S' -- \
		log_msg "'skipping as already installed (mark file "%s" exist)\n'" \
			"'${MARK_FILE#$DEST/}'"
	exit 0
else
	: >"$MARK_FILE" ||
		abort '%s: mark file "%s" is not writable\n' \
			"$prog_name" "$MARK_FILE"
fi

# Make sure we known effective uid/gid we running
INSTALL_EUID="${INSTALL_EUID:-${EUID:-$(id -u)}}" ||
	abort '%s: fail to get process effective UID\n' "$prog_name"
INSTALL_EGID="${INSTALL_EGID:-${EGID:-$(id -g)}}" ||
	abort '%s: fail to get process effective GID\n' "$prog_name"
export INSTALL_EUID INSTALL_EGID

# Configure EXIT "signal" handler
exit_handler()
{
	local rc=$?
	if [ $rc -ne 0 ]; then
		exec_vars V=1 -- msg "'%s: install exited with error %d\n'" \
			"'$NAME/install.sh'" $rc
	fi

	if [ -z "$PARENT" ]; then
		msg '%s: installation log file located at "%s"\n' \
			"$NAME" "$INSTALL_LOG"
	fi
}
trap exit_handler EXIT

# Source vars-sh with global variables and/or functions that may be
# exported to subprojects using shell export directive
. "$SOURCE/vars-sh"

# Prepare templates
SUBST_TEMPLATES="$(echo "$SUBST_TEMPLATES" |sort -u)"

# Call subprojects install
log_msg '---- Start subproject installations ----\n'

for sp in "$SOURCE/.subprojects"/*; do
	# Check subproject directory
	[ -d "$sp" ] || continue

	# Check it's install.sh
	install_sh="$sp/install.sh"
	if [ -f "$install_sh" -a \
	     -r "$install_sh" -a \
	     -x "$install_sh" ]; then
		# then execute
		exec_vars PARENT="$NAME" -- "$install_sh" ||
			abort '%s: subproject "%s/install.sh" failed\n' \
				"$prog_name" "${sp##*/}"
	fi
done

log_msg '---- Stop subproject installations ----\n'

# Install to the given destination (DEST)
install_dest \
	'/netctl'

# Install system wide (ROOT) configuration files
install_root \
	'/bin'    \
	'/boot'   \
	'/dev'    \
	'/etc'    \
	'/home'   \
	'/lib'    \
	'/libx32' \
	'/lib32'  \
	'/lib64'  \
	'/media'  \
	'/mnt'    \
	'/opt'    \
	'/root'   \
	'/sbin'   \
	'/srv'    \
	'/usr'    \
	'/var'

# Source project specific code
install_sh="$SOURCE/install-sh"
if [ -f "$install_sh" ]; then
	. "$install_sh" "$@" ||
		abort '%s: "%s/install-sh" failed\n' \
			"$prog_name" "$NAME"
fi

exit 0
