#!/bin/ash
# shellcheck shell=dash
# shellcheck disable=SC2086,SC3047,SC3036,SC3010,SC3001,SC3060,SC3015
# alpine  busybox ash
#  bash  ash 
# [[ a = '*a' ]] && echo 1

# 
set -eE

#  reinstall.sh  trans.sh 
# shellcheck disable=SC2034
SCRIPT_VERSION=4BACD833-A585-23BA-6CBB-9AA4E08E0004

TRUE=0
FALSE=1
EFI_UUID=C12A7328-F81F-11D2-BA4B-00A0C93EC93B

error() {
    color='\e[31m'
    plain='\e[0m'
    echo -e "${color}***** ERROR *****${plain}" >&2
    echo -e "${color}$*${plain}" >&2
}

info() {
    color='\e[32m'
    plain='\e[0m'
    local msg

    if [ "$1" = false ]; then
        shift
        msg=$*
    else
        msg=$(echo "$*" | to_upper)
    fi

    echo -e "${color}***** $msg *****${plain}" >&2
}

warn() {
    color='\e[33m'
    plain='\e[0m'
    echo -e "${color}Warning: $*${plain}" >&2
}

error_and_exit() {
    error "$@"

    if is_have_cmd sudo; then
        sudo_='sudo '
    elif is_have_cmd doas; then
        sudo_='doas '
    else
        sudo_=
    fi

    echo "Run '$sudo_/trans.sh' to retry." >&2
    echo "Run '$sudo_/trans.sh alpine' to install Alpine Linux instead." >&2

    # 
    # passwd -u "$username" >/dev/null

    #  alpine  ssh
    # 

    exit 1
}

trap_err() {
    line_no=$1
    ret_no=$2

    error_and_exit "$(
        echo "Line $line_no return $ret_no"
        if [ -f "/trans.sh" ]; then
            sed -n "$line_no"p /trans.sh
        fi
    )"
}

is_run_from_locald() {
    [[ "$0" = "/etc/local.d/*" ]]
}

# reinstall.sh  add_community_repo_for_alpine
add_community_repo() {
    local ver mirror

    #  repo  edge  latest-stable
    if grep -q "^http.*/edge/main$" /etc/apk/repositories; then
        ver=edge
    elif grep -q "^http.*/latest-stable/main$" /etc/apk/repositories; then
        ver=latest-stable
    else
        ver=v$(cut -d. -f1,2 </etc/alpine-release)
    fi

    if ! grep -q "^http.*/$ver/community$" /etc/apk/repositories; then
        mirror=$(grep '^http.*/main$' /etc/apk/repositories | sed 's,/[^/]*/main$,,' | head -1)
        echo $mirror/$ver/community >>/etc/apk/repositories
    fi
}

# 
# 
apk() {
    retry 5 command apk "$@" >&2
}

show_url_in_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
        [Hh][Tt][Tt][Pp][Ss]://* | [Hh][Tt][Tt][Pp]://* | [Mm][Aa][Gg][Nn][Ee][Tt]:*) echo "$1" ;;
        esac
        shift
    done
}

killall() {
    # killall 
    local ret=0
    if ! command killall "$@"; then
        ret=$?
    fi
    sleep 5
    return $ret
}

#  set +o pipefail 
# retry 5 command wget | head -c 1048576  retry 5 
# command wget "$@" --tries=5 | head -c 1048576  wget  retry 1 
wget() {
    show_url_in_args "$@" >&2
    if command wget 2>&1 | grep -q BusyBox; then
        # busybox wget 
        # 
        retry 5 command wget "$@" -T 10
    else
        #  wget 
        command wget --tries=5 --progress=bar:force "$@"
    fi
}

is_have_cmd() {
    # command -v 
    is_have_cmd_on_disk / "$1"
}

is_have_cmd_on_disk() {
    local os_dir=$1
    local cmd=$2

    for bin_dir in /bin /sbin /usr/bin /usr/sbin; do
        if [ -f "$os_dir$bin_dir/$cmd" ]; then
            return
        fi
    done
    return 1
}

is_num() {
    echo "$1" | grep -Exq '[0-9]*\.?[0-9]*'
}

retry() {
    local max_try=$1
    shift

    if is_num "$1"; then
        local interval=$1
        shift
    else
        local interval=5
    fi

    local i
    for i in $(seq $max_try); do
        if "$@"; then
            return
        else
            ret=$?
            # wget -O- | grep -m1  141 
            # 
            if [ $ret -eq 141 ]; then
                return
            fi
            if [ $i -ge $max_try ]; then
                return $ret
            fi
            sleep $interval
        fi
    done
}

get_url_type() {
    if [[ "$1" = magnet:* ]]; then
        echo bt
    else
        echo http
    fi
}

is_magnet_link() {
    [[ "$1" = magnet:* ]]
}

create_alpine_rootfs() {
    local os_dir=$1
    local init_now=${2:-false}

    #  /etc/apk 
    mkdir -p "$os_dir"
    cp -a --parents /etc/apk "$os_dir"
    rm -f "$os_dir/etc/apk/world"

    #  alpine
    apk add --root "$os_dir" --initdb \
        alpine-base openssl ca-certificates

    if $init_now; then
        cp_resolv_conf "$os_dir"
        mount_pseudo_fs "$os_dir"
    fi
}

create_alpine_rootfs_with_arch_install_scripts() {
    local os_dir=$1
    local init_now=${2:-false}
    local parent_os_dir=$3

    create_alpine_rootfs "$os_dir" $init_now

    #  alpine-base  world alpine-base alpine-conf
    # --installed --depends 
    #  --installed 
    alpine_base_depends=$(chroot "$os_dir" apk info --installed --depends alpine-base | sed '/depends on:/d')
    chroot "$os_dir" apk add $alpine_base_depends
    chroot "$os_dir" apk del alpine-base alpine-conf
    chroot "$os_dir" apk add arch-install-scripts

    if [ -n "$parent_os_dir" ]; then
        mkdir -p "$os_dir/parent"
        mount --rbind "$parent_os_dir" "$os_dir/parent"
    fi
}

remove_alpine_rootfs() {
    local os_dir=$1

    umount_pseudo_fs "$os_dir"
    rm -rf "$os_dir"
}

download_via_browser() {
    local url=$1
    local path=$2

    local os_dir=/os/alpine_for_browser
    mkdir_clear "$os_dir"

    #  chromium-headless-shell npm 
    create_alpine_rootfs "$os_dir" true
    apk add --root "$os_dir" chromium-headless-shell npm

    #  playwright
    # shellcheck disable=SC2046
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 \
        chroot "$os_dir" \
        npm install \
        --no-save --no-package-lock \
        --prefix "/work" \
        $(is_in_china && echo '--registry=https://registry.npmmirror.com') \
        playwright

    # 
    # shellcheck disable=SC2154
    wget "$confhome/download-via-browser.js" -O "$os_dir/work/download-via-browser.js"
    retry 5 chroot "$os_dir" node /work/download-via-browser.js "$url" "/work/download_file"
    cp "$os_dir/work/download_file" "$path"

    # 
    remove_alpine_rootfs "$os_dir"
}

download() {
    local url=$1
    local path=$2
    local can_use_cn_mirror=${3:-false}

    # ipv4ipv4aria2ipv4ipv6
    # axel  lightsail cpu
    # https://download.opensuse.org/distribution/leap/15.5/appliances/openSUSE-Leap-15.5-Minimal-VM.x86_64-kvm-and-xen.qcow2
    # https://aria2.github.io/manual/en/html/aria2c.html#cmdoption-o

    #  user-agent  axel/aria2 
    # aria2  --max-tries 5

    #  --max-tries=5aria2
    #  for 
    #     [ERROR] CUID#7 - Download aborted. URI=https://aka.ms/manawindowsdrivers
    # Exception: [AbstractCommand.cc:351] errorCode=1 URI=https://aka.ms/manawindowsdrivers
    #   -> [SocketCore.cc:1019] errorCode=1 SSL/TLS handshake failure:  `not signed by known authorities or invalid'

    #  if 
    # if aria2c xxx; then
    #     return
    # fi

    # --user-agent=Wget/1.21.1 \
    # --retry-wait 5

    # 
    if [ "$(get_url_type "$url")" = bt ]; then
        torrent="$(get_torrent_path_by_magnet $url)"
        if ! [ -f "$torrent" ]; then
            download_torrent_by_magnet "$url" "$torrent"
        fi
        url=$torrent
    fi

    # intel  aria2 
    # intel  wget 
    #  virtio  aria2 

    # -o  http 
    # -O  bt 
    set -- \
        -d "$(dirname "$path")" \
        -o "$(basename "$path")" \
        -O "1=$(basename "$path")" \
        -U curl/7.54.1

    if ! aria2c "$url" "$@" &&
        ! { $can_use_cn_mirror && is_in_china && is_any_ipv4_has_internet &&
            url_cn=https://files.m.daocloud.io/$(echo "$url" | sed -E 's,^https?://,,i') &&
            aria2c "$url_cn" "$@"; }; then
        error_and_exit "Failed to download $url"
    fi

    # opensuse  metalink
    # aria2  metalink 
    # 
    if head -c 1024 "$path" | grep -Fq 'urn:ietf:params:xml:ns:metalink'; then
        real_file=$(tr -d '\n' <"$path" | sed -E 's|.*<file[[:space:]]+name="([^"]*)".*|\1|')
        mv "$(dirname "$path")/$real_file" "$path"
    fi
}

update_part() {
    sleep 1
    sync

    # partprobe
    #  Resource busy 
    if is_have_cmd partprobe; then
        partprobe /dev/$xda 2>/dev/null || true
    fi

    # partx
    # https://access.redhat.com/solutions/199573
    if is_have_cmd partx; then
        partx -u /dev/$xda
    fi

    # mdev
    # mdev  /dev/disk/ 
    #  rm -rf  mdev rm -rf  Directory not empty
    #  mdev 
    #  /dev/$xda*?
    ensure_service_stopped mdev
    #  mdev Directory not empty retry
    retry 5 rm -rf /dev/disk/*

    #  modloop 
    # modprobe: can't change directory to '/lib/modules': No such file or directory
    # 
    mdev -sf 2>/dev/null
    ensure_service_started mdev 2>/dev/null
    sleep 1
}

is_efi() {
    if [ -n "$force_boot_mode" ]; then
        [ "$force_boot_mode" = efi ]
    else
        [ -d /sys/firmware/efi/ ]
    fi
}

is_use_cloud_image() {
    [ -n "$cloud_image" ] && [ "$cloud_image" = 1 ]
}

is_allow_ping() {
    [ -n "$allow_ping" ] && [ "$allow_ping" = 1 ]
}

setup_nginx() {
    apk add nginx
    # shellcheck disable=SC2154
    wget $confhome/logviewer.html -O /logviewer.html
    wget $confhome/logviewer-nginx.conf -O /etc/nginx/http.d/default.conf

    sed -i "s/@WEB_PORT@/$web_port/gi" /etc/nginx/http.d/default.conf

    # rc-service -q nginx start
    if pgrep nginx >/dev/null; then
        nginx -s reload
    else
        nginx
    fi
}

setup_websocketd() {
    apk add websocketd
    wget $confhome/logviewer.html -O /tmp/index.html
    apk add coreutils

    killall -q websocketd || true
    # websocketd  \n  \r  \n
    websocketd --port "$web_port" --loglevel=fatal --staticdir=/tmp \
        stdbuf -oL -eL sh -c "tail -fn+0 /reinstall.log | tr '\r' '\n' | grep -Fiv -e password -e token" &
}

get_approximate_ram_size() {
    # lsmem  util-linux
    if false && is_have_cmd lsmem; then
        ram_size=$(lsmem -b 2>/dev/null | grep 'Total online memory:' | awk '{ print $NF/1024/1024 }')
    fi

    if [ -z $ram_size ]; then
        ram_size=$(free -m | awk '{print $2}' | sed -n '2p')
    fi

    echo "$ram_size"
}

setup_web_if_enough_ram() {
    total_ram=$(get_approximate_ram_size)
    # 512
    if [ "$total_ram" -ge 400 ]; then
        # lighttpd 
        # setup_lighttpd
        # setup_nginx
        setup_websocketd
    fi
}

setup_lighttpd() {
    apk add lighttpd
    ln -sf /reinstall.html /var/www/localhost/htdocs/index.html
    rc-service -q lighttpd start
}

get_ttys() {
    prefix=$1
    # shellcheck disable=SC2154
    wget $confhome/ttys.sh -O- | sh -s $prefix
}

find_xda() {
    #  id 
    #  xda  xda  /configs/xda

    # 
    if xda=$(get_config xda 2>/dev/null) && [ -n "$xda" ]; then
        return
    fi

    #  $main_disk 
    if [ -z "$main_disk" ]; then
        error_and_exit "cmdline main_disk is empty."
    fi

    # busybox fdisk/lsblk/blkid  mbr  id
    # 
    # fdisk  util-linux-misc 
    # sfdisk 
    # lsblk
    # blkid

    tool=sfdisk

    is_have_cmd $tool && need_install_tool=false || need_install_tool=true
    if $need_install_tool; then
        apk add $tool
    fi

    if [ "$tool" = sfdisk ]; then
        # sfdisk
        for disk in $(get_all_disks); do
            if sfdisk --disk-id "/dev/$disk" | sed 's/0x//' | grep -ix "$main_disk"; then
                xda=$disk
                break
            fi
        done
    else
        # lsblk
        xda=$(lsblk --nodeps -rno NAME,PTUUID | grep -iw "$main_disk" | awk '{print $1}')
    fi

    if [ -n "$xda" ]; then
        set_config xda "$xda"
    else
        error_and_exit "Could not find xda: $main_disk"
    fi

    if $need_install_tool; then
        apk del $tool
    fi
}

get_all_disks() {
    # shellcheck disable=SC2010
    ls /sys/block/ | grep -Ev '^(loop|sr|nbd)'
}

extract_env_from_cmdline() {
    #  finalos/extra 
    for prefix in finalos extra; do
        while read -r line; do
            if [ -n "$line" ]; then
                key=$(echo $line | cut -d= -f1)
                value=$(echo $line | cut -d= -f2-)
                eval "$key='$value'"
            fi
        done < <(xargs -n1 </proc/cmdline | grep "^${prefix}_" | sed "s/^${prefix}_//")
    done

    # 
    if [ "$distro" = windows ]; then
        username=${username:-administrator}
    else
        username=${username:-root}
    fi
    ssh_port=${ssh_port:-22}
    rdp_port=${rdp_port:-3389}
    web_port=${web_port:-80}
}

ensure_service_started() {
    local service=$1

    if ! rc-service -q "$service" start; then
        for i in $(seq 10); do
            if [ "$service" = modloop ]; then
                #  modloop 
                # * Failed to verify signature of !
                # mount: mounting /dev/loop0 on /.modloop failed: Invalid argument
                rm -f /lib/modloop-lts /lib/modloop-virt
            fi
            if rc-service -q "$service" start; then
                return
            fi
            sleep 5
        done
        error_and_exit "Failed to start $service."
    fi
}

ensure_service_stopped() {
    local service=$1

    if ! retry 10 5 rc-service -q "$service" stop; then
        error_and_exit "Failed to stop $service."
    fi
}

mod_motd() {
    #  alpine 
    #  alpine $distro
    file=/etc/motd
    if ! [ -e $file.orig ]; then
        cp $file $file.orig
        # shellcheck disable=SC2016
        echo "mv "\$mnt$file.orig" "\$mnt$file"" |
            insert_into_file "$(which setup-disk)" before 'cleanup_chroot_mounts "\$mnt"'

        cat <<EOF >$file
Reinstalling...
To view logs run:
tail -fn+1 /reinstall.log
EOF
    fi
}

umount_all() {
    dirs="/mnt /os /iso /wim /wim-tmp /installer /nbd /nbd-boot /nbd-efi /nbd-test /root /nix"
    regex=$(echo "$dirs" | sed 's, ,|,g')
    if mounts=$(mount | grep -Ew "on $regex" | awk '{print $3}' | tac); then
        for mount in $mounts; do
            echo "umount $mount"
            umount $mount
        done
    fi
}

# 
clear_previous() {
    if is_have_cmd vgchange; then
        umount -R /os /nbd || true
        vgchange -an
        apk add device-mapper
        dmsetup remove_all
    fi
    disconnect_qcow
    #  arch  gpg-agent 
    #  aria2c aria2c 
    killall -q gpg-agent aria2c || true
    rc-service -q --ifexists --ifstarted nix-daemon stop
    swapoff -a
    umount_all

    #  umount -R /1  busy
    # mount /file1 /1
    # mount /1/file2 /2
}

# virt-what  dmidecode
cache_dmi_and_virt() {
    if ! [ "$_dmi_and_virt_cached" = 1 ]; then
        apk add virt-what

        #  kvm  virtio:
        # 1.  c8y virt-what  kvm
        # 2.  kvm  virtio  aws nitro
        # 3. virt-what  virtio
        _virt=$(
            virt-what

            # hyper-v  modprobe virtio_scsi  /sys/bus/virtio/drivers/virtio_scsi
            #  devices  /sys/bus/virtio/drivers/*
            #  lspci ?

            #  ls /sys/bus/virtio/devices/* && echo virtio
            #  0 
            if ls /sys/bus/virtio/devices/* >/dev/null 2>&1; then
                echo virtio
            fi
        )

        _dmi=$(dmidecode | grep -E '(Manufacturer|Asset Tag|Vendor): ' | awk -F': ' '{print $2}')
        _dmi_and_virt_cached=1
        apk del virt-what
    fi
}

is_virt() {
    cache_dmi_and_virt
    [ -n "$_virt" ]
}

is_virt_contains() {
    cache_dmi_and_virt
    echo "$_virt" | grep -Eiwq "$1"
}

is_dmi_contains() {
    # Manufacturer: Alibaba Cloud
    # Manufacturer: Tencent Cloud
    # Manufacturer: Huawei Cloud
    # Asset Tag: OracleCloud.com
    # Vendor: Amazon EC2
    # Manufacturer: Amazon EC2
    # Asset Tag: Amazon EC2
    cache_dmi_and_virt
    echo "$_dmi" | grep -Eiwq "$1"
}

cache_lspci() {
    if [ -z "$_lspci" ]; then
        apk add pciutils
        _lspci=$(lspci)
        apk del pciutils
    fi
}

is_lspci_contains() {
    cache_lspci
    echo "$_lspci" | grep -Eiwq "$1"
}

get_config() {
    cat "/configs/$1"
}

set_config() {
    printf '%s' "$2" >"/configs/$1"
}

# ubuntu el/ol 
get_password_linux_sha512() {
    get_config password-linux-sha512
}

get_password_windows_administrator_base64() {
    get_config password-windows-administrator-base64
}

get_password_windows_user_base64() {
    get_config password-windows-user-base64
}

get_password_plaintext() {
    get_config password-plaintext
}

is_password_plaintext() {
    get_password_plaintext >/dev/null 2>&1
}

show_netconf() {
    grep -r . /dev/netconf/
}

get_ra_to() {
    if [ -z "$_ra" ]; then
        apk add ndisc6
        # 
        echo "Gathering network info..."
        # shellcheck disable=SC2154
        _ra="$(rdisc6 -1 "$ethx")"
        apk del ndisc6

        # 
        info "Network info:"
        echo
        echo "$_ra" | cat -n
        echo
        ip addr | cat -n
        echo
        show_netconf | cat -n
        echo
    fi
    eval "$1='$_ra'"
}

get_netconf_to() {
    case "$1" in
    slaac | dhcpv6 | rdnss | other) get_ra_to ra ;;
    esac

    # shellcheck disable=SC2154
    # debian initrd  xargs
    case "$1" in
    slaac) echo "$ra" | grep 'Autonomous address conf' | grep -q Yes && res=1 || res=0 ;;
    dhcpv6) echo "$ra" | grep 'Stateful address conf' | grep -q Yes && res=1 || res=0 ;;
    rdnss) res=$(echo "$ra" | grep 'Recursive DNS server' | cut -d: -f2-) ;;
    other) echo "$ra" | grep 'Stateful other conf' | grep -q Yes && res=1 || res=0 ;;
    *) res=$(cat /dev/netconf/$ethx/$1) ;;
    esac

    eval "$1='$res'"
}

is_any_ipv4_has_internet() {
    grep -q 1 /dev/netconf/*/ipv4_has_internet
}

is_in_china() {
    grep -q 1 /dev/netconf/*/is_in_china
}

#  dhcpv4  vultr  ipv6
#  dhcpv4 ip ip
is_dhcpv4() {
    if ! is_ipv4_has_internet || should_disable_dhcpv4; then
        return 1
    fi

    get_netconf_to dhcpv4
    # shellcheck disable=SC2154
    [ "$dhcpv4" = 1 ]
}

is_staticv4() {
    if ! is_ipv4_has_internet; then
        return 1
    fi

    if ! is_dhcpv4; then
        get_netconf_to ipv4_addr
        get_netconf_to ipv4_gateway
        if [ -n "$ipv4_addr" ] && [ -n "$ipv4_gateway" ]; then
            return 0
        fi
    fi
    return 1
}

is_staticv6() {
    if ! is_ipv6_has_internet; then
        return 1
    fi

    if ! is_slaac && ! is_dhcpv6; then
        get_netconf_to ipv6_addr
        get_netconf_to ipv6_gateway
        if [ -n "$ipv6_addr" ] && [ -n "$ipv6_gateway" ]; then
            return 0
        fi
    fi
    return 1
}

is_dhcpv6_or_slaac() {
    get_netconf_to dhcpv6_or_slaac
    # shellcheck disable=SC2154
    [ "$dhcpv6_or_slaac" = 1 ]
}

is_ipv4_has_internet() {
    get_netconf_to ipv4_has_internet
    # shellcheck disable=SC2154
    [ "$ipv4_has_internet" = 1 ]
}

is_ipv6_has_internet() {
    get_netconf_to ipv6_has_internet
    # shellcheck disable=SC2154
    [ "$ipv6_has_internet" = 1 ]
}

should_disable_dhcpv4() {
    get_netconf_to should_disable_dhcpv4
    # shellcheck disable=SC2154
    [ "$should_disable_dhcpv4" = 1 ]
}

should_disable_accept_ra() {
    get_netconf_to should_disable_accept_ra
    # shellcheck disable=SC2154
    [ "$should_disable_accept_ra" = 1 ]
}

should_disable_autoconf() {
    get_netconf_to should_disable_autoconf
    # shellcheck disable=SC2154
    [ "$should_disable_autoconf" = 1 ]
}

is_slaac() {
    #  IP  1 ra
    # slaac/dhcpv6ip/

    #  ra  dhcpv6/slaac  ipv6 
    # is_dhcpv6_or_slaac  1

    #  is_staticv6
    if ! is_ipv6_has_internet || ! is_dhcpv6_or_slaac || should_disable_accept_ra || should_disable_autoconf; then
        return 1
    fi
    get_netconf_to slaac
    # shellcheck disable=SC2154
    [ "$slaac" = 1 ]
}

is_dhcpv6() {
    #  IP  1 ra
    # slaac/dhcpv6ip/

    #  ra  dhcpv6/slaac  ipv6 
    # is_dhcpv6_or_slaac  1

    #  is_staticv6
    if ! is_ipv6_has_internet || ! is_dhcpv6_or_slaac || should_disable_accept_ra || should_disable_autoconf; then
        return 1
    fi
    get_netconf_to dhcpv6

    # shellcheck disable=SC2154
    #  IPv6 RA DHCPv6 
    #  DHCPv6 
    #  DHCPv6
    if [ "$dhcpv6" = 1 ] && ! ip -6 -o addr show scope global dev "$ethx" | grep -q .; then
        echo 'DHCPv6 flag is on, but DHCPv6 is not working.'
        return 1
    fi

    [ "$dhcpv6" = 1 ]
}

is_have_ipv6() {
    is_slaac || is_dhcpv6 || is_staticv6
}

is_enable_other_flag() {
    get_netconf_to other
    # shellcheck disable=SC2154
    [ "$other" = 1 ]
}

is_have_rdnss() {
    # rdnss 
    get_netconf_to rdnss
    [ -n "$rdnss" ]
}

# dd  windows 
is_windows() {
    [ "$distro" = windows ]
}

# 15063  rdnss
is_windows_support_rdnss() {
    [ "$build_ver" -ge 15063 ]
}

get_windows_version_from_windows_drive() {
    local os_dir=$1

    # https://wiki.tcl-lang.org/page/Windows+OS+name
    # https://nsis.sourceforge.io/Get_Windows_version

    # win10+  CurrentMajorVersionNumber  CurrentMinorVersionNumber
    # CurrentVersion            6.3
    # CurrentMajorVersionNumber  10
    # CurrentMinorVersionNumber   0

    apk add hivex-perl
    hive=$(find_file_ignore_case $os_dir/Windows/System32/config/SOFTWARE)

    get_current_version_key() {
        hivexget "$hive" "Microsoft\Windows NT\CurrentVersion" "$1"
    }

    # nt_ver
    if { nt_ver_major=$(get_current_version_key CurrentMajorVersionNumber) &&
        nt_ver_minor=$(get_current_version_key CurrentMinorVersionNumber); } 2>/dev/null; then
        nt_ver="$nt_ver_major.$nt_ver_minor"
    else
        # en_windows_vista_sp2_x64_dvd_342267.iso
        #  CurrentVersion  6.0
        #  CurrentVersion  6.0

        # en_windows_vista_sp2_with_update_6003.23713_aio_7in1_x64_v26.01.13_by_adguard.iso
        #  CurrentVersion  6.0.6002.18005
        #  CurrentVersion  6.0

        #  cut 
        nt_ver=$(get_current_version_key CurrentVersion | cut -d. -f1-2)
    fi

    # build_ver
    # win10 22h2 19045  exe/dll  19041 
    # vista sp2 iso  KB4474419 , CurrentBuild  6002, CurrentBuildNumber  6003
    build_ver=$(get_current_version_key CurrentBuildNumber)

    # rev_ver
    #  win10 winver  UBR  revision 
    # vista sp2 iso  UBR UBR
    if ! rev_ver=$(get_current_version_key UBR 2>/dev/null); then
        rev_ver=$(get_current_version_key BuildLabEx | cut -d. -f2)
    fi

    echo "Version: $nt_ver.$build_ver.$rev_ver" >&2
    apk del hivex-perl
}

is_elts() {
    [ -n "$elts" ] && [ "$elts" = 1 ]
}

is_need_set_ssh_keys() {
    [ -s /configs/ssh_keys ]
}

is_need_change_ssh_port() {
    [ -n "$ssh_port" ] && ! [ "$ssh_port" = 22 ]
}

is_need_change_rdp_port() {
    [ -n "$rdp_port" ] && ! [ "$rdp_port" = 3389 ]
}

is_need_manual_set_dnsv6() {
    #  rdnss
    ! is_have_ipv6 && return $FALSE
    is_dhcpv6 && return $FALSE
    is_staticv6 && return $TRUE
    is_slaac && ! is_enable_other_flag &&
        { ! is_have_rdnss || { is_have_rdnss && is_windows && ! is_windows_support_rdnss; }; }
}

get_current_dns() {
    mark=$(
        case "$1" in
        4) echo . ;;
        6) echo : ;;
        esac
    )
    # debian 11 initrd  xargs awk
    # debian 12 initrd  xargs
    if false; then
        grep '^nameserver' /etc/resolv.conf | awk '{print $2}' | grep -F "$mark" | cut -d '%' -f1
    else
        grep '^nameserver' /etc/resolv.conf | cut -d' ' -f2 | grep -F "$mark" | cut -d '%' -f1
    fi
}

to_upper() {
    tr '[:lower:]' '[:upper:]'
}

to_lower() {
    tr '[:upper:]' '[:lower:]'
}

del_cr() {
    sed 's/\r$//'
}

del_comment_lines() {
    sed '/^[[:space:]]*#/d'
}

del_empty_lines() {
    sed '/^[[:space:]]*$/d'
}

del_head_empty_lines_inplace() {
    #  ^[:space:]
    # 
    sed -i '1,/[^[:space:]]/ { /^[[:space:]]*$/d }' "$@"
}

get_part_num_by_part() {
    dev_part=$1
    echo "$dev_part" | grep -o '[0-9]*' | tail -1
}

get_fallback_efi_file_name() {
    case $(arch) in
    x86_64) echo bootx64.efi ;;
    aarch64) echo bootaa64.efi ;;
    *) error_and_exit ;;
    esac
}

del_invalid_efi_entry() {
    info "del invalid EFI entry"
    apk add lsblk efibootmgr

    efibootmgr --quiet --remove-dups

    while read -r line; do
        part_uuid=$(echo "$line" | awk -F ',' '{print $3}')
        efi_index=$(echo "$line" | grep_efi_index)
        if ! lsblk -o PARTUUID | grep -q "$part_uuid"; then
            echo "Delete invalid EFI Entry: $line"
            efibootmgr --quiet --bootnum "$efi_index" --delete-bootnum
        fi
    done < <(efibootmgr | grep 'HD(.*,GPT,')
}

# reinstall.sh 
grep_efi_index() {
    awk '{print $1}' | sed -e 's/Boot//' -e 's/\*//'
}

#  bootx64.efi
#  ECS  EFI Shell
#  bootx64.efi  EFI Shell
# 
add_default_efi_to_nvram() {
    info "add default EFI to nvram"

    apk add lsblk efibootmgr

    if efi_row=$(lsblk /dev/$xda -ro NAME,PARTTYPE,PARTUUID | grep -i "$EFI_UUID"); then
        efi_part_uuid=$(echo "$efi_row" | awk '{print $3}')
        efi_part_name=$(echo "$efi_row" | awk '{print $1}')
        efi_part_num=$(get_part_num_by_part "$efi_part_name")
        efi_file=$(get_fallback_efi_file_name)

        # 
        # 
        if true || ! efibootmgr | grep -i "HD($efi_part_num,GPT,$efi_part_uuid,.*)/File(\\\EFI\\\boot\\\\$efi_file)"; then
            efibootmgr --create \
                --disk "/dev/$xda" \
                --part "$efi_part_num" \
                --label "$efi_file" \
                --loader "\\EFI\\boot\\$efi_file"
        fi
    else
        # shellcheck disable=SC2154
        if [ "$confirmed_no_efi" = 1 ]; then
            echo 'Confirmed no EFI in previous step.'
        else
            # reinstall.sh  512 
            # 
            echo "
Warning: This machine is currently using EFI boot, but the main hard drive does not have an EFI partition.
If this machine supports Legacy BIOS boot (CSM), you can safely restart into the new system by running the reboot command.
If this machine does not support Legacy BIOS boot (CSM), you will not be able to enter the new system after rebooting.

 EFI  EFI 
 Legacy BIOS  (CSM) reboot 
 Legacy BIOS  (CSM)
"
            exit
        fi
    fi
}

unix2dos() {
    target=$1

    # unix2doscat
    if ! command unix2dos $target 2>/tmp/unix2dos.log; then
        #  unix2dos 
        rm "$(awk -F: '{print $2}' /tmp/unix2dos.log | xargs)"
        tmp=$(mktemp)
        cp $target $tmp
        command unix2dos $tmp
        # cat 
        cat $tmp >$target
        rm $tmp
    fi
}

insert_into_file() {
    local file=$1
    local location=$2
    local regex_to_find=$3
    shift 3

    if ! [ -f "$file" ]; then
        error_and_exit "File not found: $file"
    fi

    #  grep -E
    if [ $# -eq 0 ]; then
        set -- -E
    fi

    if [ "$location" = head ]; then
        bak=$(mktemp)
        cp $file $bak
        cat - $bak >$file
    else
        line_num=$(grep "$@" -n "$regex_to_find" "$file" | cut -d: -f1)

        found_count=$(echo "$line_num" | wc -l)
        if [ ! "$found_count" -eq 1 ]; then
            return 1
        fi

        case "$location" in
        before) line_num=$((line_num - 1)) ;;
        after) ;;
        *) return 1 ;;
        esac

        sed -i "${line_num}r /dev/stdin" "$file"
    fi
}

get_eths() {
    (
        cd /dev/netconf
        ls
    )
}

is_distro_like_debian() {
    [ "$distro" = debian ] || [ "$distro" = kali ]
}

create_ifupdown_config() {
    conf_file=$1

    rm -f $conf_file

    if is_distro_like_debian; then
        cat <<EOF >>$conf_file
source /etc/network/interfaces.d/*

EOF
    fi

    #  lo
    cat <<EOF >>$conf_file
auto lo
iface lo inet loopback
EOF

    # ethx
    for ethx in $(get_eths); do
        mode=auto
        # shellcheck disable=SC2154
        if false; then
            if { [ "$distro" = debian ] && [ "$releasever" -ge 12 ]; } ||
                [ "$distro" = kali ]; then
                # alice + allow-hotplug 
                #  1 debian 9/10/11/12:
                # /etc/networking/interfaces  ethx 
                #  networking  fix-eth-name.sh 
                # :  /etc/networking/interfaces enp3s0 
                #  2 debian 9/10/11:
                #  systemctl restart networking 
                # : /lib/systemd/system/networking.service  hotplug  debian 12+ 
                if [ -f /etc/network/devhotplug ] && grep -wo "$ethx" /etc/network/devhotplug; then
                    mode=allow-hotplug
                fi
            fi

            # if is_have_cmd udevadm; then
            #     enpx=$(udevadm test-builtin net_id /sys/class/net/$ethx 2>&1 | grep ID_NET_NAME_PATH= | cut -d= -f2)
            # fi
        fi

        # dmit debian  rename
        #  ens18
        #    ens18
        #      enp6s18
        # https://bugs.debian.org/cgi-bin/bugreport.cgi?bug=928923

        # 
        get_netconf_to mac_addr
        {
            echo
            # fix-eth-name 
            # shellcheck disable=SC2154
            echo "# mac $mac_addr"
            echo $mode $ethx
        } >>$conf_file

        # ipv4
        if is_dhcpv4; then
            echo "iface $ethx inet dhcp" >>$conf_file

        elif is_staticv4; then
            get_netconf_to ipv4_addr
            get_netconf_to ipv4_gateway
            cat <<EOF >>$conf_file
iface $ethx inet static
    address $ipv4_addr
    gateway $ipv4_gateway
EOF
            # dns
            if list=$(get_current_dns 4); then
                for dns in $list; do
                    cat <<EOF >>$conf_file
    dns-nameservers $dns
EOF
                done
            fi
        fi

        # ipv6
        if is_slaac; then
            echo "iface $ethx inet6 auto" >>$conf_file

        elif is_dhcpv6; then
            # debian 13  ifupdown + dhcpcd-base
            # inet/inet6  dhcp  dhcpv4 
            #  systemctl restart networking 
            #  dhcpcd-base  isc-dhcp-client debian 12  13 dhcpv6 
            if { [ "$distro" = debian ] && [ "$releasever" -ge 13 ]; } ||
                [ "$distro" = kali ]; then
                echo "iface $ethx inet6 auto" >>$conf_file
            else
                echo "iface $ethx inet6 dhcp" >>$conf_file
            fi

        elif is_staticv6; then
            get_netconf_to ipv6_addr
            get_netconf_to ipv6_gateway
            cat <<EOF >>$conf_file
iface $ethx inet6 static
    address $ipv6_addr
    gateway $ipv6_gateway
EOF
            # debian 9
            # ipv4  onlink 
            # ipv6  onlink  post-up 
            # ipv6  ip route add default via xxx onlink
            if [ "$distro" = debian ] && [ "$releasever" -le 9 ]; then
                # debian  gateway  post-up
                #  gateway post-up 

                #  gateway
                sed -Ei '$s/^( *)/\1# /' "$conf_file"
                cat <<EOF >>$conf_file
    post-up ip route add $ipv6_gateway dev $ethx
    post-up ip route add default via $ipv6_gateway dev $ethx
EOF
            fi

            #  IPv6 
            get_netconf_to ipv6_extra_addrs
            if [ -n "$ipv6_extra_addrs" ]; then
                (
                    IFS=','
                    for _addr in $ipv6_extra_addrs; do
                        echo "    post-up ip -6 addr add $_addr dev $ethx" >>$conf_file
                    done
                )
            fi
        fi

        # dns
        #  ipv6  dns 
        if is_need_manual_set_dnsv6; then
            for dns in $(get_current_dns 6); do
                cat <<EOF >>$conf_file
    dns-nameserver $dns
EOF
            done
        fi

        #  ra
        if should_disable_accept_ra; then
            if [ "$distro" = alpine ]; then
                cat <<EOF >>$conf_file
    pre-up echo 0 >/proc/sys/net/ipv6/conf/$ethx/accept_ra
EOF
            else
                cat <<EOF >>$conf_file
    accept_ra 0
EOF
            fi
        fi

        #  autoconf
        if should_disable_autoconf; then
            if [ "$distro" = alpine ]; then
                cat <<EOF >>$conf_file
    pre-up echo 0 >/proc/sys/net/ipv6/conf/$ethx/autoconf
EOF
            else
                cat <<EOF >>$conf_file
    autoconf 0
EOF
            fi
        fi
    done
}

newline_to_comma() {
    tr '\n' ','
}

space_to_newline() {
    sed 's/ /\n/g'
}

trim() {
    sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'
}

quote_word() {
    sed -E 's/([^[:space:]]+)/"\1"/g'
}

quote_line() {
    awk '{print "\""$0"\""}'
}

add_space() {
    space_count=$1

    spaces=$(printf '%*s' "$space_count" '')
    sed "s/^/$spaces/"
}

# 
nix_replace() {
    local key=$1
    local value=$2
    local type=$3
    local file=$4
    local key_ value_

    key_=$(echo "$key" | sed 's \. \\\. g') # .  \.

    if [ "$type" = array ]; then
        local value_="[ $value ]"
    fi

    sed -i "s/$key_ =.*/$key = $value_;/" "$file"
}

create_nixos_network_config() {
    conf_file=$1
    true >$conf_file

    # 
    cat <<EOF >>$conf_file
networking = {
  usePredictableInterfaceNames = false;
EOF

    for ethx in $(get_eths); do
        # ipv4  DHCP  useDHCP
        if is_dhcpv4; then
            cat <<EOF >>$conf_file
  interfaces.$ethx.useDHCP = true;
EOF
        fi

        # ipv4
        if is_staticv4; then
            get_netconf_to ipv4_addr
            get_netconf_to ipv4_gateway
            IFS=/ read -r address prefix < <(echo "$ipv4_addr")
            cat <<EOF >>$conf_file
  interfaces.$ethx.ipv4.addresses = [
    {
      address = "$address";
      prefixLength = $prefix;
    }
  ];
  defaultGateway = {
    address = "$ipv4_gateway";
    interface = "$ethx";
  };
EOF
        fi

        # ipv6
        if is_staticv6; then
            get_netconf_to ipv6_addr
            get_netconf_to ipv6_gateway
            IFS=/ read -r address prefix < <(echo "$ipv6_addr")
            cat <<EOF >>$conf_file
  interfaces.$ethx.ipv6.addresses = [
    {
      address = "$address";
      prefixLength = $prefix;
    }
  ];
  defaultGateway6 = {
    address = "$ipv6_gateway";
    interface = "$ethx";
  };
EOF
        fi
    done

    #  dns
    need_set_dns=false
    for ethx in $(get_eths); do
        if is_staticv4 || is_staticv6 || is_need_manual_set_dnsv6; then
            need_set_dns=true
            break
        fi
    done

    if $need_set_dns; then
        cat <<EOF >>$conf_file
  nameservers = [
$(get_current_dns | quote_line | add_space 4)
  ];
EOF
    fi

    # 
    cat <<EOF >>$conf_file
};
EOF

    # nixos  dhcpcd
    #  ip 
    # /nix/store/qcr1xxjdxcrnwqwrgysqpxx2aibp9fdl-unit-script-network-addresses-eth0-start/bin/network-addresses-eth0-start
    # ...
    # if out=$(ip addr replace "181.x.x.x/24" dev "eth0" 2>&1); then
    #   echo "done"
    # else
    #   echo "'ip addr replace "181.x.x.x/24" dev "eth0"' failed: $out"
    #   exit 1
    # fi
    # ...

    #  ra/autoconf
    local mode=1
    for ethx in $(get_eths); do
        if should_disable_accept_ra; then
            case "$mode" in
            1)
                cat <<EOF >>$conf_file
boot.kernel.sysctl."net.ipv6.conf.$ethx.accept_ra" = false;
EOF
                ;;
            2)
                # nixos  ip 
                # 
                cat <<EOF >>$conf_file
networking.dhcpcd.extraConfig =
  ''
    interface $ethx
      ipv6ra_noautoconf
  '';
EOF
                ;;
            3)
                #  networkd
                cat <<EOF >>$conf_file
systemd.network.networks.$ethx = {
   matchConfig.Name = "$ethx";
   networkConfig = {
     IPv6AcceptRA = false;
   };
 };
EOF
                ;;
            esac
        fi

        if should_disable_autoconf; then
            case "$mode" in
            1)
                cat <<EOF >>$conf_file
boot.kernel.sysctl."net.ipv6.conf.$ethx.autoconf" = false;
EOF
                ;;
            2) ;;
            3) ;;
            esac
        fi
    done
}

install_alpine() {
    info "install alpine"

    need_ram=512
    swap_size=$(get_need_swap_size $need_ram)
    [ "$swap_size" -gt 0 ] && hack_lowram=true || hack_lowram=false

    # alpine  firmware
    # https://github.com/alpinelinux/alpine-conf/blob/3.18.1/setup-disk.in#L421
    #  modloop 
    #  modloop  firmware 
    fw_pkgs=$(get_alpine_firmware_pkgs)

    if $hack_lowram; then
        # 
        if rc-service -q modloop status; then
            modules="ext4 vfat nls_utf8 nls_cp437"
            for mod in $modules; do
                modprobe $mod
            done
            # crc32c  crc32c-intel
            #  sse4.2  crc32c  modprobe: ERROR: could not insert 'crc32c_intel': No such device
            modprobe crc32c || modprobe crc32c-generic
        fi

        #  modloop 
        ensure_service_stopped modloop
        rm -f /lib/modloop-lts /lib/modloop-virt
    fi

    # bios setup-disk  boot 
    # 
    create_part
    mount_part_basic_layout /os /os/boot/efi

    #  swap
    if $hack_lowram; then
        create_swap $swap_size /os/swapfile
    fi

    # 
    create_ifupdown_config /etc/network/interfaces
    echo
    cat -n /etc/network/interfaces
    echo

    #  arm netboot initramfs init 
    # rtchwclockswclock
    # 
    # initramfs chrootrtc
    # hwclock
    rc-update del swclock boot || true
    rc-update add hwclock boot

    #  setup-alpine 
    # https://github.com/alpinelinux/alpine-conf/blob/3.18.1/setup-alpine.in#L229

    # boot
    rc-update add networking boot
    rc-update add seedrng boot

    # default
    rc-update add crond
    if [ -e /dev/input/event0 ]; then
        rc-update add acpid
    fi

    #  vm  virt 
    if is_virt; then
        kernel_flavor="virt"
    else
        kernel_flavor="lts"
    fi

    # 
    # mirror
    if false; then
        true >/etc/apk/repositories
        setup-apkrepos -1
    fi

    # setup-disk  grub  nvram
    #  fallback  bootx64.efi
    if is_efi; then
        apk add efibootmgr
        sed -i 's/--no-nvram//' "$(which setup-disk)"
    fi

    # 
    # alpine syslinux (efi ) grub
    KERNELOPTS="$(get_ttys console=)"
    export KERNELOPTS
    export BOOTLOADER="grub"
    setup-disk -m sys -k $kernel_flavor /os

    #  setup-disk 
    apk del e2fsprogs dosfstools efibootmgr grub*

    #  /proc

    # 1. chroot /os setup-keymap us us 
    # grep: /proc/filesystems: No such file or directory

    # 2.  grub-probe
    # Executing grub-2.12-r5.trigger
    # /usr/sbin/grub-probe: error: failed to get canonical path of `/dev/vda1'.
    # ERROR: grub-2.12-r5.trigger: script exited with error 1

    mount_pseudo_fs /os

    # 
    #  Live OS 

    # 
    # udhcpc
    # 1 ip -4 addr  dhcp
    # 2 networking  udhcpc6
    # 3 h3c  udhcpc6  dhcpv6

    # dhcpcd
    # 1 slaacip

    # slaac1: udhcpc + rdnssd
    # slaac2: dhcpcd + 
    # dhcpv6: dhcpcd

    # dhcpcd
    # 1 /etc/network/interfacesraslaacdhcpv6
    # 2 rdnss
    # 3 

    #  dhcpcd
    chroot /os apk add dhcpcd
    chroot /os sed -i '/^slaac private/s/^/#/' /etc/dhcpcd.conf
    chroot /os sed -i '/^#slaac hwaddr/s/^#//' /etc/dhcpcd.conf

    # 
    chroot /os setup-keymap us us
    chroot /os setup-timezone -i Asia/Shanghai
    # 3.21  chrony
    # 3.22  busybox ntp
    printf '\n' | chroot /os setup-ntp || true

    # 
    add_user_if_need /os
    if is_need_set_ssh_keys; then
        set_ssh_keys_and_del_password /os
    fi

    # alpine 3.24+
    #  /etc/inittab  tty0
    #  vnc  tty0 tty1

    # sed  # enable login on alternative console 
    #  N 
    #  \ntty0:
    sed -i '
/^# enable login on alternative console$/{
    N
    /\ntty0:/d
}
' /os/etc/inittab

    #  fix-eth-name
    download "$confhome/fix-eth-name.sh" /os/fix-eth-name.sh
    download "$confhome/fix-eth-name.initd" /os/etc/init.d/fix-eth-name
    chmod +x /os/etc/init.d/fix-eth-name
    chroot /os rc-update add fix-eth-name boot

    #  frpc
    if ls /configs/frpc.* >/dev/null 2>&1; then
        chroot /os apk add frp
        # chroot rc-update add  sysinit
        #  chroot  default
        chroot /os rc-update add frpc boot
        cp -f /configs/frpc.* /os/etc/frp/
    fi

    # setup-disk 
    # https://github.com/alpinelinux/alpine-conf/blob/3.18.1/setup-disk.in#L421
    if fw_pkgs="$fw_pkgs $(get_ucode_firmware_pkgs)" && [ -n "$fw_pkgs" ]; then
        chroot /os apk add $fw_pkgs
    fi

    # 3.19  efi  grub
    if ! is_efi; then
        chroot /os grub-install --target=i386-pc /dev/$xda
    fi

    # efi grub  fwsetup 
    chroot /os update-grub

    #  swap
    if [ -e /os/swapfile ]; then
        if false; then
            echo "/swapfile swap swap defaults 0 0" >>/os/etc/fstab
            ln -sf /etc/init.d/swap /os/etc/runlevels/boot/swap
        else
            swapoff -a
            rm /os/swapfile
        fi
    fi
}

get_cpu_vendor() {
    cpu_vendor=$(grep 'vendor_id' /proc/cpuinfo | head -1 | awk '{print $NF}')
    case "$cpu_vendor" in
    GenuineIntel) echo intel ;;
    AuthenticAMD) echo amd ;;
    *) echo other ;;
    esac
}

min() {
    printf "%d\n" "$@" | sort -n | head -n 1
}

# 
#  cpu 
get_build_threads() {
    threads_per_mb=$1

    threads_by_core=$(nproc)
    threads_by_ram=$(($(get_approximate_ram_size) / threads_per_mb))
    [ $threads_by_ram -eq 0 ] && threads_by_ram=1
    min $threads_by_ram $threads_by_core
}

add_newline() {
    # shellcheck disable=SC1003
    case "$1" in
    head | start) sed -e '1s/^/\n/' ;;
    tail | end) sed -e '$a\\' ;;
    both) sed -e '1s/^/\n/' -e '$a\\' ;;
    esac
}

install_nixos() {
    info "Install NixOS"

    local os_dir=/os
    keep_swap=true
    nix_from=website
    ram_per_thread=2048

    threads=$(get_build_threads $ram_per_thread)
    swap_size=$(get_need_swap_size $ram_per_thread)

    show_nixos_config() {
        echo
        #  frp auth.token
        cat -n /os/etc/nixos/configuration.nix | grep -Fv 'auth.token'
        echo
        cat -n /os/etc/nixos/hardware-configuration.nix
        echo
    }

    #  swapfile
    mount_part_basic_layout /os /os/efi
    if [ "$swap_size" -gt 0 ]; then
        create_swap "$swap_size" /os/swapfile
    fi

    # 
    # 1.  nix (nix-xxx)
    # 2.  nix  nixos-install-tools (nixos-xxx)
    # 3.  nixos-generate-config  + 
    # 4.  nixos-install
    # https://nixos.org/manual/nixos/stable/index.html#sec-installing-from-other-distro

    # nix                                               
    # apk add nix                                    3.20         2.22.0  # nix  alpine  /nix/store 
    # env -iA nixpkgs.nix                            24.05        2.18.5
    # sh <(curl -L https://nixos.org/nix/install)   unstable?     2.24.2

    # apk add  nix 
    # copying path '/nix/store/gcbrjlfm5h21ybf1h2lfq773zafjmzjr-curl-8.7.1-man' from 'https://cache.nixos.org'...
    #  cpu 

    #  nix
    mkdir -p /os/nix /nix
    mount --bind /os/nix /nix

    # nix  /root/.nix-profile/etc/profile.d/nix.sh 
    #  alpine local.d 
    export USER=root
    export HOME=/root

    #  export NIX_CONFIG  --option substituters https://mirror.nju.edu.cn/nix-channels/store
    # https://help.mirrorz.org/nix-channels/
    configure_nix_substituters() {
        if ! is_in_china; then
            return
        fi

        nix_conf=/etc/nix/nix.conf
        mkdir -p "$(dirname "$nix_conf")"

        if [ -f "$nix_conf" ]; then
            sed -i '/^[[:space:]]*substituters[[:space:]]*=/d' "$nix_conf"
        fi

        echo "substituters = $mirror/store" >>"$nix_conf"
    }

    case "$nix_from" in
    alpine)
        apk add nix
        #  nix 
        # alpine  4 
        # https://gitlab.alpinelinux.org/alpine/aports/-/blob/master/community/nix/APKBUILD#L125
        sed -i '/max-jobs/d' /etc/nix/nix.conf
        echo "max-jobs = $threads" >>/etc/nix/nix.conf
        configure_nix_substituters
        rc-service -q nix-daemon restart
        #  nix-env  PATH
        PATH="/root/.nix-profile/bin:$PATH"
        ;;
    website)
        # https://gitlab.alpinelinux.org/alpine/aports/-/blob/master/community/nix/nix.pre-install
        # https://nix.dev/manual/nix/latest/installation/multi-user
        if ! grep -q nixbld /etc/passwd; then
            addgroup -S nixbld
            for n in $(seq 1 10); do
                adduser -S -D -H -h /var/empty -s /sbin/nologin -G nixbld \
                    -g "Nix build user $n" nixbld$n
            done
        fi

        # 
        # 1.  https://mirror.nju.edu.cn/nix-channels/nixos-26.05/nixexprs.tar.xz 
        #    https://github.com/NixOS/nixpkgs/blob/nixos-26.05/pkgs/tools/package-management/nix/default.nix
        #    https://github.com/NixOS/nixpkgs/blob/nixos-26.05/nixos/modules/installer/tools/nix-fallback-paths.nix
        # 2.  nix nixos channel 
        #    nix eval -f '<nixpkgs>' --raw 'nixVersions.stable.version' --extra-experimental-features nix-command

        if true; then
            # nix 
            download $mirror/nixos-$releasever/store-paths.xz /os/store-paths.xz
            apk add xz
            nix_ver=$(xz -dc </os/store-paths.xz | grep -F 'vm-test-run-nix-upgrade' |
                head -1 | awk -F- '{print $7}' | grep .)
            rm -f /os/store-paths.xz
            if is_in_china; then
                sh_mirror=https://mirror.nju.edu.cn/nix
            else
                sh_mirror=https://releases.nixos.org/nix
            fi
            sh=$sh_mirror/nix-$nix_ver/install
        else
            #  nix  nixos-install 
            # https://github.com/bin456789/reinstall/issues/451
            if is_in_china; then
                sh=https://mirror.nju.edu.cn/nix/latest/install
            else
                sh=https://nixos.org/nix/install
            fi
        fi

        apk add xz
        wget -O- "$sh" | sh -s -- --no-daemon --no-channel-add
        apk del xz
        # shellcheck source=/dev/null
        . /root/.nix-profile/etc/profile.d/nix.sh
        configure_nix_substituters
        ;;
    esac

    #  channel
    # shellcheck disable=SC2154
    nix-channel --add $mirror/nixos-$releasever nixpkgs
    nix-channel --update

    #  channal  nix
    # shellcheck source=/dev/null
    if false; then
        nix-env -iA nixpkgs.nix -j $threads
        . ~/.nix-profile/etc/profile.d/nix.sh
    fi

    #  nixos-install-tools
    nix-env -iA nixpkgs.nixos-install-tools -j $threads

    #  nixfmt
    nix-env -iA nixpkgs.nixfmt -j $threads

    # 
    nixos-generate-config --root /os
    echo "Original NixOS Configuration:"
    show_nixos_config

    #  configuration.nix
    if is_efi; then
        nix_bootloader="boot.loader.efi.efiSysMountPoint = \"/efi\";"
    else
        nix_bootloader="boot.loader.grub.device = \"/dev/$xda\";"
    fi

    if is_in_china; then
        nix_substituters="nix.settings.substituters = lib.mkForce [ \"$mirror/store\" ];"
    fi

    if [ -e /os/swapfile ] && $keep_swap; then
        nix_swap="swapDevices = [ { device = \"/swapfile\"; size = $swap_size; } ];"
    fi

    # keys
    if is_need_set_ssh_keys; then
        nix_user_keys_fragment="
openssh.authorizedKeys.keys = [
$(del_comment_lines </configs/ssh_keys | del_empty_lines | quote_line | add_space 2)
];
"
    fi

    # root user
    if [ "$username" = root ]; then
        if is_need_set_ssh_keys; then
            nix_users="
users.users.$username = {
$(echo "$nix_user_keys_fragment" | add_space 2)
};
"
        else
            nix_users=""
        fi
    else
        # normal user
        # https://nixos.org/manual/nixos/stable/#sec-user-management
        nix_users=$(
            cat <<EOF
users.users.$username = {
  isNormalUser = true;
  home = "/home/$username";
  extraGroups = [
    "wheel"
    "networkmanager"
  ];
$(echo "$nix_user_keys_fragment" | add_space 2)
};

security.sudo.extraRules = [
  { users = [ "$username" ]; commands = [ { command = "ALL"; options = [ "NOPASSWD" ]; } ]; }
];
EOF
        )
    fi

    # openssh
    nix_openssh="
services.openssh = {
  enable = true;
$(
        {
            if is_need_change_ssh_port; then
                echo "ports = [ $ssh_port ];"
            fi
            if is_need_set_ssh_keys; then
                echo 'settings.PasswordAuthentication = false;'
            fi
            if [ "$username" = root ] && ! is_need_set_ssh_keys; then
                echo 'settings.PermitRootLogin = "yes";'
            fi
        } | add_space 2
    )
};
"

    # frpc
    if ls /configs/frpc.* >/dev/null 2>&1; then
        nix_frpc=$(
            if false; then
                #  frpc.toml  toml   frpc.toml
                #  frpc.toml 
                #  frpc  ini json yaml
                # 
                cat <<EOF
services.frp = {
  enable = true;
  role = "client";
  settings = builtins.fromTOML ''
$(cat /configs/frpc.* | add_space 4)
  '';
};
EOF
            else
                # 
                (
                    umask 077
                    cp /configs/frpc.* /os/etc/nixos/
                )
                ext=$(basename /configs/frpc.* | awk -F. '{print $NF}')
                cat <<EOF
services.frp = {
  enable = true;
  role = "client";
};
systemd.services.frp.serviceConfig = {
  LoadCredential = "frpc.$ext:/etc/nixos/frpc.$ext";
  ExecStart = lib.mkForce "\${pkgs.frp}/bin/frpc -c \\\${CREDENTIALS_DIRECTORY}/frpc.$ext";
};
EOF
            fi
        )
    fi

    # TODO:  udev  networkd  mac
    create_nixos_network_config /tmp/nixos_network_config.nix

    del_empty_lines <<EOF | add_space 2 | add_newline both |
############### Add by reinstall.sh ###############
$nix_bootloader
$nix_swap
$nix_substituters
boot.kernelParams = [ $(get_ttys console= | quote_word) ];
$nix_users
$nix_openssh
$nix_frpc
$(cat /tmp/nixos_network_config.nix)
###################################################
EOF
        insert_into_file /os/etc/nixos/configuration.nix before "networking.hostName" -F

    #  hardware-configuration.nix
    #  vultr efi nixos-generate-config  virtio_pci
    #  virtio_blk  initrd 
    #  alpine  virtio_pci 
    #  nixos-generate-config  virtio_pci 
    olds=$(
        grep -F 'boot.initrd.availableKernelModules' /os/etc/nixos/hardware-configuration.nix |
            cut -d= -f2 | tr -d '"[];' | xargs
    )
    alls="$olds"
    # https://github.com/search?q=repo%3ANixOS%2Fnixpkgs+availableKernelModules&type=code
    for mod in ahci ata_piix uhci_hcd sr_mod nvme vmd \
        virtio_pci virtio_blk virtio_scsi \
        xen_blkfront xen_scsifront \
        hv_storvsc pci_hyperv \
        vmw_pvscsi \
        mptspi; do
        if [ -d /sys/module/$mod ] && ! echo "$olds" | grep -wq "$mod"; then
            echo "Adding modules: $mod"
            alls="$alls $mod"
        fi
    done
    # 
    alls=$(echo "$alls" | xargs)

    # boot.initrd.availableKernelModules = [ "ata_piix" "uhci_hcd" "virtio_pci" "sr_mod" "virtio_blk" ];
    nix_replace \
        boot.initrd.availableKernelModules \
        "$(echo "$alls" | quote_word)" \
        array \
        /os/etc/nixos/hardware-configuration.nix

    # 
    nixfmt /os/etc/nixos/configuration.nix
    nixfmt /os/etc/nixos/hardware-configuration.nix

    # 
    echo "Modified NixOS Configuration:"
    show_nixos_config

    # 
    nixos-install --root /os --no-root-passwd -j $threads

    # 
    if ! is_need_set_ssh_keys; then
        printf '%s\n' "$username:$(get_password_linux_sha512)" | nixos-enter --root /os -- \
            /run/current-system/sw/bin/chpasswd -e
    fi

    #  channel
    if is_in_china; then
        nixos-enter --root /os -- \
            /run/current-system/sw/bin/nix-channel --add $mirror/nixos-$releasever nixos
    fi

    # 
    nix-env -e '*'
    # /nix/var/nix/profiles/system/sw/bin/nix-collect-garbage -d
    /nix/var/nix/profiles/system/sw/bin/nixos-enter --root /os -- \
        /run/current-system/sw/bin/nix-collect-garbage -d

    #  nix
    umount /nix
    apk del nix

    # swapfile
    if [ -e /os/swapfile ]; then
        if $keep_swap; then
            :
        else
            swapoff -a
            rm -rf /os/swapfile
        fi
    fi

    # 
    show_nixos_config
}

add_systemd_service() {
    local os_dir=$1
    local service_name=$2

    download "$confhome/$service_name.service" "$os_dir/etc/systemd/system/$service_name.service"
    chroot "$os_dir" systemctl enable "$service_name.service"

    # aosc  preset-all
    #  fix-eth-name  preset 
    #  /etc/systemd/system/multi-user.target.wants/fix-eth-name.service 
    #  /etc/systemd/system-preset/ 

    #  /usr/lib/systemd/system-preset/  /lib/systemd/system-preset/
    if [ -d "$os_dir/usr/lib/systemd/system-preset" ]; then
        echo "enable $service_name.service" >"$os_dir/usr/lib/systemd/system-preset/01-$service_name.preset"
    else
        echo "enable $service_name.service" >"$os_dir/lib/systemd/system-preset/01-$service_name.preset"
    fi
}

add_fix_eth_name_systemd_service() {
    local os_dir=$1

    #  systemctl daemon-reload
    #  chroot  Running in chroot, ignoring command 'daemon-reload'
    download "$confhome/fix-eth-name.sh" "$os_dir/fix-eth-name.sh"
    add_systemd_service "$os_dir" fix-eth-name
}

get_frpc_url() {
    wget "$confhome/get-frpc-url.sh" -O- | sh -s "$@"
}

add_frpc_systemd_service_if_need() {
    local os_dir=$1

    if ls /configs/frpc.* >/dev/null 2>&1; then
        mkdir -p "$os_dir/usr/local/bin"
        mkdir -p "$os_dir/usr/local/etc/frpc"

        #  frpc
        #  frpc owner  root:root
        frpc_url=$(get_frpc_url linux)
        basename=$(echo "$frpc_url" | awk -F/ '{print $NF}' | sed 's/\.tar\.gz//')
        download "$frpc_url" "$os_dir/frpc.tar.gz"
        # busybox tar  wildcard
        # tar: */frpc: not found in archive
        tar xzf "$os_dir/frpc.tar.gz" "$basename/frpc" -O >"$os_dir/usr/local/bin/frpc"
        rm -f "$os_dir/frpc.tar.gz"
        chmod a+x "$os_dir/usr/local/bin/frpc"

        # frpc conf
        cp -f /configs/frpc.* "$os_dir/usr/local/etc/frpc/"

        # 
        add_systemd_service "$os_dir" frpc
    fi
}

get_fs_of_mount_point() {
    local mount_point=$1

    if ! [ "$mount_point" = / ]; then
        #  /
        mount_point=$(printf "%s" "$mount_point" | sed 's,/*$,,')
    fi

    # findmnt 
    # findmnt "$mount_point" -rno FSTYPE
    mount | awk -v mp="$1" '$3==mp {print $5}' | grep .
}

basic_init() {
    local os_dir=$1

    # 
    # chroot $os_dir timedatectl set-timezone Asia/Shanghai
    # Failed to create bus connection: No such file or directory

    # debian 11  systemd-firstboot
    if is_have_cmd_on_disk $os_dir systemd-firstboot; then
        if chroot $os_dir systemd-firstboot --help | grep -wq '\--force'; then
            chroot $os_dir systemd-firstboot --timezone=Asia/Shanghai --force
        else
            chroot $os_dir systemd-firstboot --timezone=Asia/Shanghai
        fi
    fi

    # gentoo  machine-id
    clear_machine_id $os_dir

    # sshd
    chroot $os_dir ssh-keygen -A

    sshd_enabled=false
    sshs="sshd.service ssh.service sshd.socket ssh.socket"
    for i in $sshs; do
        if chroot $os_dir systemctl -q is-enabled $i; then
            sshd_enabled=true
            break
        fi
    done
    if ! $sshd_enabled; then
        for i in $sshs; do
            if chroot $os_dir systemctl -q enable $i; then
                break
            fi
        done
    fi

    if is_need_change_ssh_port; then
        change_ssh_port $os_dir $ssh_port
    fi

    # /
    add_user_if_need "$os_dir"
    if is_need_set_ssh_keys; then
        set_ssh_keys_and_del_password $os_dir
        change_ssh_conf_for_key_login $os_dir
    else
        change_user_password $os_dir
        change_ssh_conf_for_password_login $os_dir
    fi

    #  fix-eth-name.service
    #  net.ifnames=0 
    #  alpine live 
    add_fix_eth_name_systemd_service $os_dir

    # frpc
    add_frpc_systemd_service_if_need $os_dir
}

install_arch_gentoo_aosc() {
    info "install $distro"

    network_app=$(
        case "$distro" in
        arch | gentoo) echo systemd-networkd ;;
        aosc) echo network-manager ;;
        esac
    )

    set_locale() {
        echo "C.UTF-8 UTF-8" >>$os_dir/etc/locale.gen
        chroot $os_dir locale-gen
    }

    # shellcheck disable=SC2317
    install_arch() {
        #  swap
        create_swap_if_ram_less_than 1024 $os_dir/swapfile

        if false; then
            local alpine_rootfs=/
            apk add arch-install-scripts
        else
            local alpine_rootfs=$os_dir/alpine
            create_alpine_rootfs_with_arch_install_scripts "$alpine_rootfs" true "$os_dir"
        fi

        #  /etc/pacman.conf 
        if [ -f $alpine_rootfs/etc/pacman.conf.orig ]; then
            cp $alpine_rootfs/etc/pacman.conf.orig $alpine_rootfs/etc/pacman.conf
        else
            cp $alpine_rootfs/etc/pacman.conf $alpine_rootfs/etc/pacman.conf.orig
        fi

        #  repo
        insert_into_file $alpine_rootfs/etc/pacman.conf before '\[core\]' <<EOF
SigLevel = Never
ParallelDownloads = 5
EOF
        cat <<EOF >>$alpine_rootfs/etc/pacman.conf
[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
EOF
        mkdir -p $alpine_rootfs/etc/pacman.d
        # shellcheck disable=SC2016
        case "$(uname -m)" in
        x86_64) dir='$repo/os/$arch' ;;
        aarch64) dir='$arch/$repo' ;;
        esac
        # shellcheck disable=SC2154
        echo "Server = $mirror/$dir" >$alpine_rootfs/etc/pacman.d/mirrorlist

        # 
        # ( fsck.xxx) initramfs 
        pkgs="base grub openssh"

        # efi fs
        if is_efi; then
            pkgs="$pkgs efibootmgr dosfstools"
        fi

        # root fs
        case $(get_fs_of_mount_point "$os_dir") in
        xfs) pkgs="$pkgs xfsprogs" ;;
        ext4) pkgs="$pkgs e2fsprogs" ;;
        btrfs) pkgs="$pkgs btrfs-progs" ;;
        esac

        if [ "$(uname -m)" = aarch64 ]; then
            pkgs="$pkgs archlinuxarm-keyring"
        fi
        if ! [ "$username" = root ]; then
            pkgs="$pkgs sudo"
        fi

        # retry 
        if [ "$alpine_rootfs" = / ]; then
            retry 5 pacstrap -K "$os_dir" $pkgs
            killall -q gpg-agent || true
            apk del arch-install-scripts
        else
            retry 5 chroot "$alpine_rootfs" pacstrap -K "/parent" $pkgs
            killall -q gpg-agent || true
            umount -R "$alpine_rootfs/parent"
            remove_alpine_rootfs "$alpine_rootfs"
        fi

        # dns
        cp_resolv_conf $os_dir

        # 
        mount_pseudo_fs $os_dir

        # 
        # ==> Creating gzip-compressed initcpio image: '/boot/initramfs-linux.img'
        # bsdtar: bsdtar: Failed to set default locale
        # Failed to set default locale
        set_locale
        if [ "$(uname -m)" = aarch64 ]; then
            chroot $os_dir pacman-key --lsign-key builder@archlinuxarm.org
        fi

        # firmware + microcode
        if fw_pkgs=$(get_ucode_firmware_pkgs) && [ -n "$fw_pkgs" ]; then
            chroot $os_dir pacman -Syu --noconfirm $fw_pkgs
        fi

        # arm  linux-aarch64 --noconfirm
        chroot $os_dir pacman -Syu --noconfirm linux
    }

    # shellcheck disable=SC2317
    install_gentoo() {
        #  swap
        create_swap_if_ram_less_than 2048 $os_dir/swapfile

        # 
        apk add tar xz pv
        # shellcheck disable=SC2154
        download "$img" $os_dir/gentoo.tar.xz
        echo "Uncompressing Gentoo..."
        pv -f $os_dir/gentoo.tar.xz | tar xpJ --numeric-owner --xattrs-include='*.*' -C $os_dir
        rm $os_dir/gentoo.tar.xz
        apk del tar xz pv

        # dns
        cp_resolv_conf $os_dir

        # 
        mount_pseudo_fs $os_dir

        #  profile
        chroot $os_dir emerge-webrsync
        profile=$(
            #  stable systemd
            if false; then
                chroot $os_dir eselect profile list | grep stable | grep systemd |
                    awk '(NR == 1 || length($2) < length(shortest)) { shortest = $2 } END { print shortest }'
            else
                chroot $os_dir eselect profile list | grep stable | grep systemd |
                    awk '{print length($2), $2}' | sort -n | head -1 | awk '{print $2}'
            fi
        )
        echo "Select profile: $profile"
        chroot $os_dir eselect profile set $profile

        #  license
        cat <<EOF >>$os_dir/etc/portage/make.conf
ACCEPT_LICENSE="*"
EOF

        cat <<EOF >>$os_dir/etc/portage/make.conf
MAKEOPTS="-j$(get_build_threads 2048)"
EOF

        #  http repo + binpkg repo
        # https://mirror.nju.edu.cn/gentoo/releases/amd64/autobuilds/current-stage3-amd64-systemd-mergedusr/stage3-amd64-systemd-mergedusr-20240317T170433Z.tar.xz
        mirror_short=$(echo "$img" | sed 's,/releases/.*,,')
        mirror_long=$(echo "$img" | sed 's,/autobuilds/.*,,')
        profile_ver=$(chroot $os_dir eselect profile show | grep -Eo '/[0-9.]*/' | cut -d/ -f2)

        if [ "$(uname -m)" = x86_64 ]; then
            if chroot $os_dir ld.so --help | grep supported | grep -q x86-64-v3; then
                binpkg_type=x86-64-v3
            else
                binpkg_type=x86-64
            fi
        else
            binpkg_type=arm64
        fi

        cat <<EOF >>$os_dir/etc/portage/make.conf
GENTOO_MIRRORS="$mirror_short"
FEATURES="getbinpkg"
EOF

        cat <<EOF >$os_dir/etc/portage/binrepos.conf/gentoobinhost.conf
[binhost]
priority = 9999
sync-uri = $mirror_long/binpackages/$profile_ver/$binpkg_type
EOF

        # 

        # getuto  ${TERM}  ${TERM}  dumb
        #  source /lib/gentoo/functions.sh  ebegin 
        #  ebegin 

        # /lib/gentoo/functions.sh  ${RC_OPENRC_PID}
        #  /functions/openrc.sh ebegin 

        #  ssh  /trans.sh  ${RC_OPENRC_PID}${TERM}  xterm
        #  chroot $os_dir getuto 

        #  locald  /trans.sh  ${RC_OPENRC_PID}${TERM}  linux
        #  chroot $os_dir getuto  ebegin: command not found

        # 
        if true; then
            TERM=dumb chroot $os_dir getuto
        else
            env -u RC_OPENRC_PID chroot $os_dir getuto
        fi

        set_locale

        #  git  glibc /etc/locale.gen  locale
        # Generating all locales; edit /etc/locale.gen to save time/space
        chroot $os_dir emerge dev-vcs/git

        #  git repo
        if is_in_china; then
            git_uri=https://mirror.nju.edu.cn/git/gentoo-portage.git
        else
            # github  ipv6
            is_any_ipv4_has_internet && git_uri=https://github.com/gentoo-mirror/gentoo.git ||
                git_uri=https://anongit.gentoo.org/git/repo/gentoo.git
        fi

        mkdir -p $os_dir/etc/portage/repos.conf
        cat <<EOF >$os_dir/etc/portage/repos.conf/gentoo.conf
[gentoo]
location = /var/db/repos/gentoo
sync-type = git
sync-uri = $git_uri
EOF
        rm -rf $os_dir/var/db/repos/gentoo
        chroot $os_dir emerge --sync

        #  rebuild ?
        local pkgs=

        # https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Tools#Filesystem_tools
        pkgs="$pkgs sys-block/io-scheduler-udev-rules"

        # efi fs
        if is_efi; then
            pkgs="$pkgs sys-fs/dosfstools sys-boot/efibootmgr"
        fi

        # root fs
        case $(get_fs_of_mount_point "$os_dir") in
        xfs) pkgs="$pkgs sys-fs/xfsprogs" ;;
        ext4) pkgs="$pkgs sys-fs/e2fsprogs" ;;
        btrfs) pkgs="$pkgs sys-fs/btrfs-progs" ;;
        esac

        # sudo
        if ! [ "$username" = root ]; then
            pkgs="$pkgs app-admin/sudo"
        fi

        # firmware + microcode
        if fw_pkgs=$(get_ucode_firmware_pkgs) && [ -n "$fw_pkgs" ]; then
            pkgs="$pkgs $fw_pkgs"
        fi

        #  grub + 
        is_efi && grub_platforms="efi-64" || grub_platforms="pc"
        echo GRUB_PLATFORMS=\"$grub_platforms\" >>$os_dir/etc/portage/make.conf
        echo "sys-kernel/installkernel dracut grub" >$os_dir/etc/portage/package.use/installkernel

        #  root=UUID=xxxx dracut 
        #  root=UUID=xxxx 
        # https://wiki.gentoo.org/wiki/Installkernel#Install_chroot_check
        # https://wiki.gentoo.org/wiki/Handbook:AMD64/Installation/Kernel#Chroot_detection
        uuid=$(chroot $os_dir findmnt -rno UUID /)
        mkdir -p $os_dir/etc/dracut.conf.d
        echo "kernel_cmdline=\" root=UUID=$uuid \"" >$os_dir/etc/dracut.conf.d/00-installkernel.conf
        pkgs="$pkgs sys-kernel/gentoo-kernel-bin"

        # 
        #  -n/--noreplace  rebuild 
        chroot "$os_dir" emerge -n $pkgs
    }

    install_aosc() {
        # 
        apk add wget tar xz
        wget "$img" -O- | tar xpJ --numeric-owner --xattrs-include='*.*' -C $os_dir
        apk del wget tar xz

        #  swap
        create_swap_if_ram_less_than 1024 $os_dir/swapfile

        # 
        mount_pseudo_fs $os_dir

        #  initramfs
        chroot $os_dir update-initramfs
    }

    local os_dir=/os

    # 
    mount_part_basic_layout /os /os/efi

    # 
    install_$distro

    #  arch  gpg-agent 
    killall -q gpg-agent || true

    # 
    if false; then
        # preset-all M
        chroot $os_dir systemctl preset-all
    fi

    # 
    case "$network_app" in
    systemd-networkd)
        chroot $os_dir systemctl enable systemd-networkd
        chroot $os_dir systemctl enable systemd-resolved

        apk add cloud-init
        # 
        useradd systemd-network || true
        create_cloud_init_network_config net.cfg
        cat -n net.cfg
        #  -D gentoo alpine  cloud-init  gentoo 
        cloud-init devel net-convert -p net.cfg -k yaml -d out -D alpine -O networkd

        #  10-cloud-init-eth*.networkfix-eth-name.sh 
        cp out/etc/systemd/network/10-cloud-init-eth*.network $os_dir/etc/systemd/network/

        # 
        sed -i '/^Name=/d' $os_dir/etc/systemd/network/10-cloud-init-eth*.network

        #  Generated by cloud-init. Changes will be lost.
        # 
        sed -i '/^# Generated by cloud-init/d' $os_dir/etc/systemd/network/10-cloud-init-eth*.network
        del_head_empty_lines_inplace $os_dir/etc/systemd/network/10-cloud-init-eth*.network

        # 
        rm -rf net.cfg out
        apk del cloud-init

        # 
        cat -n $os_dir/etc/systemd/network/10-cloud-init-eth*.network
        ;;
    network-manager)
        chroot $os_dir systemctl enable NetworkManager

        #  alpine  cloud-init  Network Manager 
        create_cloud_init_network_config /net.cfg
        create_network_manager_config /net.cfg "$os_dir"
        rm /net.cfg
        ;;
    esac

    # arch gentoo  alpine cloud-init 
    # cloud-init  onlink 

    basic_init $os_dir

    # ntp  systemd 
    # TODO: vm agent + 

    # grub
    if is_efi; then
        # arch gentoo  efi  /efi
        chroot $os_dir grub-install --efi-directory=/efi
        chroot $os_dir grub-install --efi-directory=/efi --removable
    else
        chroot $os_dir grub-install /dev/$xda
    fi

    # cmdline +  grub.cfg
    if [ -d $os_dir/etc/default/grub.d ]; then
        file=$os_dir/etc/default/grub.d/tty.cfg
    else
        file=$os_dir/etc/default/grub
    fi
    ttys_cmdline=$(get_ttys console=)
    echo GRUB_CMDLINE_LINUX=\"\$GRUB_CMDLINE_LINUX $ttys_cmdline\" >>$file
    chroot $os_dir grub-mkconfig -o /boot/grub/grub.cfg

    # fstab
    # fstab  efi  systemd automount 
    # fstab  >>
    local alpine_rootfs=$os_dir/alpine
    create_alpine_rootfs_with_arch_install_scripts "$alpine_rootfs" true "$os_dir"
    # genfstab  findmnt 
    retry 5 chroot "$alpine_rootfs" apk add util-linux
    chroot "$alpine_rootfs" genfstab -U /parent | sed '/swap/d' >>$os_dir/etc/fstab
    umount -R "$alpine_rootfs/parent"
    remove_alpine_rootfs "$alpine_rootfs"

    #  resolv.conf systemd-resolved 
    rm_resolv_conf $os_dir

    #  swap
    swapoff -a
    rm -rf $os_dir/swapfile
}

get_http_file_size() {
    url=$1

    #  Content-Length, 
    wget --spider -S "$url" 2>&1 | grep 'Content-Length:' |
        tail -1 | awk '{print $2}' | grep .
}

get_url_hash() {
    url=$1

    echo "$url" | md5sum | awk '{print $1}'
}

aria2c() {
    if ! is_have_cmd aria2c; then
        apk add aria2
    fi

    # stdbuf  coreutils 
    if ! is_have_cmd stdbuf; then
        apk add coreutils
    fi

    #  url
    show_url_in_args "$@" >&2

    #  tracker
    #  sub shell 
    if echo "$@" | grep -Eq 'magnet:|\.torrent' && ! [ -f "/tmp/trackers" ]; then
        # 
        # 
        # txt=$(wget -O- https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_best.txt | grep .)
        # txt=$(wget -O- https://raw.githubusercontent.com/ngosang/trackerslist/master/trackers_all.txt | grep .)
        txt=$(wget -O- https://cf.trackerslist.com/best.txt | grep .)
        # sed 
        echo "$txt" | newline_to_comma | sed 's/,$//' >/tmp/trackers
    fi

    # --dht-entry-point=router.bittorrent.com:6881 \
    # --dht-entry-point=dht.transmissionbt.com:6881 \
    # --dht-entry-point=router.utorrent.com:6881 \
    retry 5 5 stdbuf -oL -eL aria2c \
        -x4 \
        --seed-time=0 \
        --allow-overwrite=true \
        --summary-interval=0 \
        --max-tries 1 \
        --bt-tracker="$([ -f "/tmp/trackers" ] && cat /tmp/trackers)" \
        "$@"
}

download_torrent_by_magnet() {
    url=$1
    dst=$2

    url_hash=$(get_url_hash "$url")

    mkdir -p /tmp/bt/$url_hash

    #  -o bt.torrent 
    aria2c "$url" \
        --bt-metadata-only=true \
        --bt-save-metadata=true \
        -d /tmp/bt/$url_hash

    mv /tmp/bt/$url_hash/*.torrent "$dst"
    rm -rf /tmp/bt/$url_hash
}

get_torrent_path_by_magnet() {
    echo "/tmp/bt/$(get_url_hash "$1").torrent"
}

get_bt_file_size() {
    url=$1

    torrent="$(get_torrent_path_by_magnet $url)"
    download_torrent_by_magnet "$url" "$torrent" >&2

    # 
    # idx|path/length
    # ===+===========================================================================
    #   1|./zh-cn_windows_11_consumer_editions_version_24h2_updated_jan_2025_x64_dvd_7a8e5a29.iso
    #    |6.1GiB (6,557,558,784)

    aria2c --show-files=true "$torrent" |
        grep -F -A1 '  1|./' | tail -1 | grep -o '(.*)' | sed -E 's/[(),]//g' | grep .
}

get_link_file_size() {
    if is_magnet_link "$1" >&2; then
        get_bt_file_size "$1"
    else
        get_http_file_size "$1"
    fi
}

pipe_extract() {
    # alpine busybox  gzip
    case "$img_type_warp" in
    xz | gzip | zstd)
        apk add $img_type_warp
        "$img_type_warp" -dc
        ;;
    tar)
        apk add tar
        tar x -O
        ;;
    tar.*)
        type=$(echo "$img_type_warp" | cut -d. -f2)
        apk add tar "$type"
        tar x "--$type" -O
        ;;
    '') cat ;;
    *) error_and_exit "Not supported img_type_warp: $img_type_warp" ;;
    esac
}

dd_raw_with_extract() {
    info "dd raw"

    #  wget
    apk add wget

    # cache22 fork: ghcr:// refs are streamed from the registry. The blob
    # is a zstd-compressed raw image; resolve a fresh anonymous token here
    # (at dd time, so it can't expire) and pipe it through pipe_extract
    # (img_type_warp=zstd) onto the disk.
    case "$img" in
    ghcr://*)
        apk add curl jq
        c22_repo=${img#ghcr://}; c22_tag=${c22_repo##*:}; c22_repo=${c22_repo%:*}
        c22_tok=$(curl -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:${c22_repo}:pull" | jq -r '.token')
        c22_dig=$(curl -fsSL -H "Authorization: Bearer ${c22_tok}" \
            -H "Accept: application/vnd.oci.image.manifest.v1+json" \
            "https://ghcr.io/v2/${c22_repo}/manifests/${c22_tag}" \
            | jq -r '.layers[] | select(.mediaType|test("octet-stream|zstd")) | .digest' | head -1)
        # Low-RAM safety (e.g. a 1 GB VPS): cap dirty page cache so writing
        # the ~11 GB decompressed image flushes steadily. Otherwise dirty
        # pages pile up, memory pressure stalls the write, the pipe back-
        # pressures curl, the idle TCP connection gets reset by the CDN, and
        # zstd reports a premature end. Steady flushing avoids the stall.
        sysctl -w vm.dirty_bytes=67108864 vm.dirty_background_bytes=33554432 >/dev/null 2>&1 || true

        # Stream the blob to disk with retries: a dropped multi-GB transfer
        # (stall-induced reset, registry CDN / token-window expiry) no longer
        # kills the install. Each attempt overwrites the device from offset 0
        # (safe full restart) and refreshes the token; --speed-time aborts a
        # stalled transfer so the retry kicks in.
        c22_ok=
        c22_try=0
        while [ "$c22_try" -lt 5 ]; do
            c22_try=$((c22_try + 1))
            info "cache22: streaming ${c22_repo} -> /dev/$xda (attempt ${c22_try}/5; bar = download, throttled by disk write)"
            # No curl --retry here: it would re-stream from byte 0 into the
            # same pipe. The outer loop does the retrying (each attempt
            # overwrites the device from offset 0). --speed-limit/--speed-time
            # aborts a stalled transfer fast so the loop kicks in.
            if curl -fL --progress-bar \
                    --speed-limit 1024 --speed-time 30 \
                    -H "Authorization: Bearer ${c22_tok}" \
                    "https://ghcr.io/v2/${c22_repo}/blobs/${c22_dig}" \
                    | pipe_extract >/dev/$xda; then
                c22_ok=1
                break
            fi
            warn "cache22: stream attempt ${c22_try} failed; refreshing token and retrying"
            sleep 3
            c22_tok=$(curl -fsSL "https://ghcr.io/token?service=ghcr.io&scope=repository:${c22_repo}:pull" | jq -r '.token')
        done
        [ -n "$c22_ok" ] || error_and_exit "cache22: ghcr stream failed after ${c22_try} attempts"
        sync
        info "cache22: image written to /dev/$xda"
        return
        ;;
    esac

    if ! wget $img -O- | pipe_extract >/dev/$xda 2>/tmp/dd_stderr; then
        # vhd  512 
        if grep -iq 'No space' /tmp/dd_stderr; then
            apk add parted
            disk_size=$(get_disk_size /dev/$xda)
            disk_end=$((disk_size - 1))

            # 
            if last_part_end=$(parted -sf /dev/$xda 'unit b print' ---pretend-input-tty |
                del_empty_lines | tail -1 | awk '{print $3}' | sed 's/B//' | grep .); then

                echo "Last part end: $last_part_end"
                echo "Disk end:      $disk_end"

                if [ "$last_part_end" -le "$disk_end" ]; then
                    echo "Safely ignore no space error."
                    return
                fi
            fi
        fi
        error_and_exit "$(cat /tmp/dd_stderr)"
    fi
}

get_disk_sector_count() {
    # cat /proc/partitions
    blockdev --getsz "$1"
}

get_disk_size() {
    blockdev --getsize64 "$1"
}

get_disk_logic_sector_size() {
    blockdev --getss "$1"
}

is_4kn() {
    [ "$(blockdev --getss "/dev/$xda")" = 4096 ]
}

is_xda_gt_2t() {
    disk_size=$(get_disk_size /dev/$xda)
    disk_2t=$((2 * 1024 * 1024 * 1024 * 1024))
    [ "$disk_size" -gt "$disk_2t" ]
}

is_ends_with_digit() {
    [[ "$1" =~ [0-9]$ ]]
}

xda() {
    if [ -n "$1" ]; then
        if is_ends_with_digit "$xda"; then
            echo "${xda}p$1"
        else
            echo "${xda}$1"
        fi
    else
        echo "$xda"
    fi
}

create_part() {
    #  dd 
    info "Create Part"

    # 
    apk add parted e2fsprogs
    if is_efi; then
        apk add dosfstools
    fi

    # 
    # TODO: iso/
    # wipefs -a /dev/$xda

    # shellcheck disable=SC2154
    if [ "$distro" = windows ]; then
        if ! size_bytes=$(get_link_file_size "$iso"); then
            #  iso  8g
            size_bytes=$((8 * 1024 * 1024 * 1024))
        fi

        # iso
        # 200m / + pagefile
        #  installer  boot.wim 200m
        # 1. vista/2008  boot.wim
        # 2.  vista/2008 --image-name 
        #  200m
        #  MiB border  MiB 
        part_size="$((size_bytes / 1024 / 1024 + 200))MiB"

        apk add ntfs-3g-progs
        # ntfs3fusewimmount
        modprobe fuse ntfs3
        if is_efi; then
            # efi
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart '" "' fat32 1MiB 1025MiB \
                mkpart '" "' fat32 1025MiB 1041MiB \
                mkpart '" "' ntfs 1041MiB -${part_size} \
                mkpart '" "' ntfs -${part_size} 100% \
                set 1 boot on \
                set 2 msftres on \
                set 3 msftdata on
            update_part

            mkfs.fat -n efi "/dev/$(xda 1)"                   #1 efi
            dd if=/dev/zero of="/dev/$(xda 2)" bs=1M count=16 #2 msr
            mkfs.ntfs -f -F -L os "/dev/$(xda 3)"             #3 os
            mkfs.ntfs -f -F -L installer "/dev/$(xda 4)"      #4 installer
        else
            # bios + mbr  2t
            if is_xda_gt_2t; then
                border=$((2 * 1024 * 1024 - ${part_size%MiB}))MiB
                max_usable_size=2TiB
            else
                border=-${part_size}
                max_usable_size=100%
            fi
            parted /dev/$xda -s -- \
                mklabel msdos \
                mkpart primary ntfs 1MiB ${border} \
                mkpart primary ntfs ${border} ${max_usable_size} \
                set 1 boot on
            update_part

            mkfs.ntfs -f -F -L os "/dev/$(xda 1)"        #1 os
            mkfs.ntfs -f -F -L installer "/dev/$(xda 2)" #2 installer
        fi
    elif [ "$distro" = fnos ]; then
        # 1. 
        # 2.  efi  1MiB-100M 1MiB-101MiB

        #  1M + 100M 
        expect_m=$((${fnos_part_size%[Gg]} * 1024))

        sector_size=$(get_disk_logic_sector_size /dev/$xda)
        total_sector_count=$(get_disk_sector_count /dev/$xda)

        #  -  -  GPT Header
        if ! is_efi && ! is_xda_gt_2t; then
            # mbr
            total_sector_count_except_backup_gpt=$total_sector_count
        elif is_4kn; then
            total_sector_count_except_backup_gpt=$((total_sector_count - 4 - 1))
        else
            total_sector_count_except_backup_gpt=$((total_sector_count - 32 - 1))
        fi

        #  MiB
        # gpt  33 (512n/512e)  5 (4Kn) 
        # parted  100%  1MiB 
        max_can_use_m=$((total_sector_count_except_backup_gpt * sector_size / 1024 / 1024))

        echo "expect_m: $expect_m"
        echo "max_can_use_m: $max_can_use_m"

        # 20G  msdos parted  part end  20480MiB 100%
        # The location 20480MiB is outside of the device /dev/vda.
        #  100%  end  20480MiB

        if [ "$expect_m" -ge "$max_can_use_m" ]; then
            warn "Expect size is equal/greater than max size. Uses max size."
            NEED_SHRINK_FNOS_OS_PART=false
            FNOS_OS_PART_END_M=$max_can_use_m
        else
            NEED_SHRINK_FNOS_OS_PART=true
            FNOS_OS_PART_END_M=$expect_m
        fi

        # fnos  grub  debian 11 
        #  metadata_csum_seed grub  grub rescue  efi 
        # orphan_file 
        ext4_opts="-O ^metadata_csum_seed,^orphan_file"

        if is_efi; then
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart BOOT fat32 1MiB 101MiB \
                mkpart SYSTEM ext4 101MiB 100% \
                set 1 esp on
            update_part

            mkfs.fat "/dev/$(xda 1)"                #1 efi
            mkfs.ext4 -F $ext4_opts "/dev/$(xda 2)" #2 os + installer
        elif is_xda_gt_2t; then
            # bios > 2t
            #  mkpart BOOT 1M 100M esp  bios_grub 
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart BOOT ext4 1MiB 101MiB \
                mkpart SYSTEM ext4 101MiB 100% \
                set 1 bios_grub on
            update_part

            echo                                    #1 bios_boot
            mkfs.ext4 -F $ext4_opts "/dev/$(xda 2)" #2 os + installer
        else
            # bios
            parted /dev/$xda -s -- \
                mklabel msdos \
                mkpart primary 1MiB 101MiB \
                mkpart primary 101MiB 100% \
                set 2 boot on
            update_part

            echo                                    #1 
            mkfs.ext4 -F $ext4_opts "/dev/$(xda 2)" #2 os + installer
        fi
    elif is_use_cloud_image; then
        installer_part_size="$(get_cloud_image_part_size)"
        # dd
        if [ "$distro" = centos ] || [ "$distro" = almalinux ] || [ "$distro" = rocky ] ||
            [ "$distro" = oracle ] || [ "$distro" = redhat ] ||
            [ "$distro" = anolis ] || [ "$distro" = opencloudos ] || [ "$distro" = openeuler ] ||
            [ "$distro" = ubuntu ]; then
            #  fs 
            fs=ext4
            if is_efi; then
                parted /dev/$xda -s -- \
                    mklabel gpt \
                    mkpart '" "' fat32 1MiB 101MiB \
                    mkpart '" "' $fs 101MiB -$installer_part_size \
                    mkpart '" "' ext4 -$installer_part_size 100% \
                    set 1 esp on
                update_part

                mkfs.fat -n efi "/dev/$(xda 1)"           #1 efi
                echo                                      #2 os 
                mkfs.ext4 -F -L installer "/dev/$(xda 3)" #3 installer
            else
                parted /dev/$xda -s -- \
                    mklabel gpt \
                    mkpart '" "' ext4 1MiB 2MiB \
                    mkpart '" "' $fs 2MiB -$installer_part_size \
                    mkpart '" "' ext4 -$installer_part_size 100% \
                    set 1 bios_grub on
                update_part

                echo                                      #1 bios_boot
                echo                                      #2 os 
                mkfs.ext4 -F -L installer "/dev/$(xda 3)" #3 installer
            fi
        else
            #  dd qcow2
            # fedora debian opensuse arch gentoo
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart '" "' ext4 1MiB -$installer_part_size \
                mkpart '" "' ext4 -$installer_part_size 100%
            update_part

            mkfs.ext4 -F -L os "/dev/$(xda 1)"        #1 os
            mkfs.ext4 -F -L installer "/dev/$(xda 2)" #2 installer
        fi
    elif [ "$distro" = alpine ] || [ "$distro" = arch ] || [ "$distro" = gentoo ] ||
        [ "$distro" = nixos ] || [ "$distro" = aosc ]; then
        # alpine  64bit ext4
        # https://gitlab.alpinelinux.org/alpine/alpine-conf/-/blob/3.18.1/setup-disk.in?ref_type=tags#L908
        #  alpine  extlinux  64bit ext4
        [ "$distro" = alpine ] && ext4_opts="-O ^64bit" || ext4_opts=
        if is_efi; then
            # efi
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart '" "' fat32 1MiB 101MiB \
                mkpart '" "' ext4 101MiB 100% \
                set 1 boot on
            update_part

            mkfs.fat "/dev/$(xda 1)"                #1 efi
            mkfs.ext4 -F $ext4_opts "/dev/$(xda 2)" #2 os
        elif is_xda_gt_2t; then
            # bios > 2t
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart '" "' ext4 1MiB 2MiB \
                mkpart '" "' ext4 2MiB 100% \
                set 1 bios_grub on
            update_part

            echo                                    #1 bios_boot
            mkfs.ext4 -F $ext4_opts "/dev/$(xda 2)" #2 os
        else
            # bios
            parted /dev/$xda -s -- \
                mklabel msdos \
                mkpart primary ext4 1MiB 100% \
                set 1 boot on
            update_part

            mkfs.ext4 -F $ext4_opts "/dev/$(xda 1)" #1 os
        fi
    else
        # ubuntu
        #  installer 
        # ubuntu ubuntu 
        # installer 2gfatubuntu-22.04.3 isoext4
        if [ "$distro" = ubuntu ]; then
            if ! size_bytes=$(get_http_file_size "$iso"); then
                #  iso 3g
                size_bytes=$((3 * 1024 * 1024 * 1024))
            fi
            installer_part_size="$(get_part_size_mb_for_file_size_b $size_bytes)MiB"
        else
            # redhat
            installer_part_size=2GiB
        fi

        # centos 7 alpineext4
        # 
        ext4_opts="-O ^metadata_csum"
        apk add dosfstools

        if is_efi; then
            # efi
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart '" "' fat32 1MiB 1025MiB \
                mkpart '" "' ext4 1025MiB -$installer_part_size \
                mkpart '" "' ext4 -$installer_part_size 100% \
                set 1 boot on
            update_part

            mkfs.fat -n efi "/dev/$(xda 1)"                      #1 efi
            mkfs.ext4 -F -L os "/dev/$(xda 2)"                   #2 os
            mkfs.ext4 -F -L installer $ext4_opts "/dev/$(xda 3)" #2 installer
        elif is_xda_gt_2t; then
            # bios > 2t
            parted /dev/$xda -s -- \
                mklabel gpt \
                mkpart '" "' ext4 1MiB 2MiB \
                mkpart '" "' ext4 2MiB -$installer_part_size \
                mkpart '" "' ext4 -$installer_part_size 100% \
                set 1 bios_grub on
            update_part

            echo                                                 #1 bios_boot
            mkfs.ext4 -F -L os "/dev/$(xda 2)"                   #2 os
            mkfs.ext4 -F -L installer $ext4_opts "/dev/$(xda 3)" #3 installer
        else
            # bios
            parted /dev/$xda -s -- \
                mklabel msdos \
                mkpart primary ext4 1MiB -$installer_part_size \
                mkpart primary ext4 -$installer_part_size 100% \
                set 1 boot on
            update_part

            mkfs.ext4 -F -L os "/dev/$(xda 1)"                   #1 os
            mkfs.ext4 -F -L installer $ext4_opts "/dev/$(xda 2)" #2 installer
        fi
        update_part
    fi

    update_part

    # alpine  256M 
    # setup-disk /dev/sda 
    if [ "$distro" = alpine ]; then
        apk del parted
    fi
}

umount_pseudo_fs() {
    local os_dir
    os_dir=$(realpath "$1")

    dirs="/proc /sys /dev /run"
    regex=$(echo "$dirs" | sed 's, ,|,g')
    if mounts=$(mount | grep -Ew "on $os_dir($regex)" | awk '{print $3}' | tac); then
        for mount in $mounts; do
            echo "umount $mount"
            umount $mount
        done
    fi
}

mount_pseudo_fs() {
    local os_dir=$1

    mkdir -p $os_dir/proc/ $os_dir/sys/ $os_dir/dev/ $os_dir/run/

    # https://wiki.archlinux.org/title/Chroot#Using_chroot
    mount -t proc /proc $os_dir/proc/
    mount -t sysfs /sys $os_dir/sys/
    mount --rbind /dev $os_dir/dev/
    mount --rbind /run $os_dir/run/
    if is_efi; then
        mount --rbind /sys/firmware/efi/efivars $os_dir/sys/firmware/efi/efivars/
    fi
}

create_cloud_init_network_config() {
    ci_file=$1
    recognize_static6=${2:-true}
    recognize_ipv6_types=${3:-true}

    info "Create Cloud-init network config"

    # 
    mkdir -p "$(dirname "$ci_file")"
    touch "$ci_file"

    apk add yq-go

    need_set_dns4=false
    need_set_dns6=false

    config_id=0
    for ethx in $(get_eths); do
        get_netconf_to mac_addr

        # shellcheck disable=SC2154
        yq -i ".network.version=1 |
           .network.config[$config_id].type=\"physical\" |
           .network.config[$config_id].name=\"$ethx\" |
           .network.config[$config_id].mac_address=(\"$mac_addr\" | . style=\"single\")
           " $ci_file

        subnet_id=0

        # ipv4
        if is_dhcpv4; then
            yq -i ".network.config[$config_id].subnets[$subnet_id] = {\"type\": \"dhcp4\"}" $ci_file
            subnet_id=$((subnet_id + 1))
        elif is_staticv4; then
            need_set_dns4=true
            get_netconf_to ipv4_addr
            get_netconf_to ipv4_gateway
            yq -i ".network.config[$config_id].subnets[$subnet_id] = {
                    \"type\": \"static\",
                    \"address\": \"$ipv4_addr\",
                    \"gateway\": \"$ipv4_gateway\" }
                    " $ci_file

            #  cloud-init  bug
            #  dns
            # 
            # https://github.com/canonical/cloud-init/commit/1b8030e0c7fd6fbff7e38ad1e3e6266ae50c83a5
            for cur in $(get_current_dns 4); do
                yq -i ".network.config[$config_id].subnets[$subnet_id].dns_nameservers += [\"$cur\"]" $ci_file
            done
            subnet_id=$((subnet_id + 1))
        fi

        # ipv6
        # slaac:  ipv6_slaac
        # └─enable_other_flag: ipv6_dhcpv6-stateless
        # dhcpv6: ipv6_dhcpv6-stateful

        # ipv6
        if is_slaac; then
            if $recognize_ipv6_types; then
                if is_enable_other_flag; then
                    type=ipv6_dhcpv6-stateless
                else
                    type=ipv6_slaac
                fi
            else
                type=dhcp6
            fi
            yq -i ".network.config[$config_id].subnets[$subnet_id] = {\"type\": \"$type\"}" $ci_file

        elif is_dhcpv6; then
            if $recognize_ipv6_types; then
                type=ipv6_dhcpv6-stateful
            else
                type=dhcp6
            fi
            yq -i ".network.config[$config_id].subnets[$subnet_id] = {\"type\": \"$type\"}" $ci_file

        elif is_staticv6; then
            get_netconf_to ipv6_addr
            get_netconf_to ipv6_gateway
            if $recognize_static6; then
                type_ipv6_static=static6
            else
                type_ipv6_static=static
            fi
            yq -i ".network.config[$config_id].subnets[$subnet_id] = {
                    \"type\": \"$type_ipv6_static\",
                    \"address\": \"$ipv6_addr\",
                    \"gateway\": \"$ipv6_gateway\" }
                    " $ci_file
        fi
        #  autoconf = false ?
        if should_disable_accept_ra; then
            yq -i ".network.config[$config_id].accept-ra = false" $ci_file
        fi

        #  ipv6  dns 
        if is_need_manual_set_dnsv6; then
            need_set_dns6=true
            for cur in $(get_current_dns 6); do
                yq -i ".network.config[$config_id].subnets[$subnet_id].dns_nameservers += [\"$cur\"]" $ci_file
            done
        fi

        config_id=$((config_id + 1))
    done

    if $need_set_dns4 || $need_set_dns6; then
        yq -i ".network.config[$config_id].type=\"nameserver\"" $ci_file
        if $need_set_dns4; then
            for cur in $(get_current_dns 4); do
                yq -i ".network.config[$config_id].address += [\"$cur\"]" $ci_file
            done
        fi
        if $need_set_dns6; then
            for cur in $(get_current_dns 6); do
                yq -i ".network.config[$config_id].address += [\"$cur\"]" $ci_file
            done
        fi
        #  network.config[$config_id]  address cloud-init 
        yq -i "del(.network.config[$config_id] | select(has(\"address\") | not))" $ci_file
    fi

    apk del yq-go

    # 
    info "Cloud-init network config"
    cat -n $ci_file >&2
}

#  machine-id 
#  lightsail centos 9  machine-id  id 
clear_machine_id() {
    local os_dir=$1

    # https://www.freedesktop.org/software/systemd/man/latest/machine-id.html
    # gentoo 
    echo uninitialized >$os_dir/etc/machine-id

    # https://build.opensuse.org/projects/Virtualization:Appliances:Images:openSUSE-Leap-15.5/packages/kiwi-templates-Minimal/files/config.sh?expand=1
    rm -f $os_dir/var/lib/systemd/random-seed
}

#  anolis 7 ?
# /etc/cloud/cloud.cfg.d/aliyun_cloud.cfg -> /sys/firmware/qemu_fw_cfg/by_name/etc/cloud-init/vendor-data/raw
download_cloud_init_config() {
    local os_dir=$1
    recognize_static6=$2
    recognize_ipv6_types=$3

    ci_file=$os_dir/etc/cloud/cloud.cfg.d/99_fallback.cfg
    download $confhome/cloud-init.yaml $ci_file
    # 
    sed -i '1!{/^[[:space:]]*#/d}' $ci_file

    # 
    #  sed 
    content=$(cat $ci_file)
    echo "${content//@PASSWORD@/$(get_password_linux_sha512)}" >$ci_file

    #  ssh 
    if is_need_change_ssh_port; then
        sed -i "s/@SSH_PORT@/$ssh_port/g" $ci_file
    else
        sed -i "/@SSH_PORT@/d" $ci_file
    fi

    # swapfile
    # swapfilearch
    if ! grep -w swap $os_dir/etc/fstab; then
        cat <<EOF >>$ci_file
swap:
  filename: /swapfile
  size: auto
EOF
    fi

    create_cloud_init_network_config "$ci_file" "$recognize_static6" "$recognize_ipv6_types"
}

get_image_state() {
    local os_dir=$1
    local image_state=

    #  dd  State.ini
    if state_ini=$(find_file_ignore_case $os_dir/Windows/Setup/State/State.ini); then
        image_state=$(grep -i '^ImageState=' $state_ini | cut -d= -f2 | tr -d '\r')
    fi
    if [ -z "$image_state" ]; then
        apk add hivex-perl
        hive=$(find_file_ignore_case $os_dir/Windows/System32/config/SOFTWARE)
        image_state=$(hivexget $hive '\Microsoft\Windows\CurrentVersion\Setup\State' ImageState)
        apk del hivex-perl
    fi

    if [ -n "$image_state" ]; then
        echo "$image_state"
    else
        error_and_exit "Cannot get ImageState."
    fi
}

modify_windows() {
    local os_dir=$1
    info "Modify Windows"

    # https://learn.microsoft.com/windows-hardware/manufacture/desktop/windows-setup-states
    # https://learn.microsoft.com/troubleshoot/azure/virtual-machines/reset-local-password-without-agent
    # https://learn.microsoft.com/windows-hardware/manufacture/desktop/add-a-custom-script-to-windows-setup

    #  SetupComplete 
    image_state=$(get_image_state "$os_dir")
    echo "ImageState: $image_state"

    if [ "$image_state" = IMAGE_STATE_COMPLETE ]; then
        use_gpo=true
    else
        use_gpo=false
    fi

    # bat 
    bats=

    # 1. rdp 
    if is_need_change_rdp_port; then
        create_win_change_rdp_port_script $os_dir/windows-change-rdp-port.bat "$rdp_port"
        bats="$bats windows-change-rdp-port.bat"
    fi

    # 2.  ping
    if is_allow_ping; then
        download $confhome/windows-allow-ping.bat $os_dir/windows-allow-ping.bat
        bats="$bats windows-allow-ping.bat"
    fi

    # 3. 
    #  unattend.xml ExtendOSPartitionresize
    download $confhome/windows-resize.bat $os_dir/windows-resize.bat
    bats="$bats windows-resize.bat"

    # 4. 
    for ethx in $(get_eths); do
        create_win_set_netconf_script $os_dir/windows-set-netconf-$ethx.bat
        bats="$bats windows-set-netconf-$ethx.bat"
    done

    # 5.  iso 
    #    Azure  Windows 
    #    
    if [ "$distro" = "windows" ] && ! is_administrator_username "$username"; then
        # 

        # 
        cat <<EOF >$os_dir/windows-set-user-password-never-expires.bat
wmic useraccount where name="$username" set passwordexpires=false || ^
powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Set-LocalUser -Name '$username' -PasswordNeverExpires \$true"
del "%~f0"
EOF
        #  || 
        cat <<EOF >$os_dir/windows-set-user-password-never-expires.bat
wmic useraccount where name="$username" set passwordexpires=false ^
  || powershell -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "Set-LocalUser -Name '$username' -PasswordNeverExpires \$true"
del "%~f0"
EOF
        unix2dos $os_dir/windows-set-user-password-never-expires.bat
        bats="$bats windows-set-user-password-never-expires.bat"
    fi

    # 6. frp
    if ls /configs/frpc.* >/dev/null 2>&1; then
        if [ "$(get_windows_arch_from_windows_drive "$os_dir" | to_lower)" = x86 ]; then
            os_bit=32
        else
            os_bit=64
        fi
        mkdir -p "$os_dir/frpc/"
        url=$(get_frpc_url windows "$nt_ver" "$os_bit")
        download "$url" $os_dir/frpc/frpc.zip
        # -j 
        # -C  busybox zip 
        unzip -o -j "$os_dir/frpc/frpc.zip" '*/frpc.exe' -d "$os_dir/frpc/"
        rm -f "$os_dir/frpc/frpc.zip"
        cp -f /configs/frpc.* "$os_dir/frpc/"
        download "$confhome/windows-frpc.xml" "$os_dir/frpc/frpc.xml"
        download "$confhome/windows-frpc.bat" "$os_dir/frpc/frpc.bat"
        bats="$bats frpc\frpc.bat"
    fi

    if $use_gpo; then
        # 
        scripts_ini=$(get_path_in_correct_case $os_dir/Windows/System32/GroupPolicy/Machine/Scripts/scripts.ini)
        mkdir -p "$(dirname $scripts_ini)"
        gpt_ini=$(get_path_in_correct_case $os_dir/Windows/System32/GroupPolicy/gpt.ini)

        #  ini
        for file in $gpt_ini $scripts_ini; do
            if [ -f $file ]; then
                cp $file $file.orig
            fi
        done

        # gpt.ini
        cat >$gpt_ini <<EOF
[General]
gPCFunctionalityVersion=2
gPCMachineExtensionNames=[{42B5FAAE-6536-11D2-AE5A-0000F87571E3}{40B6664F-4972-11D1-A7CA-0000F87571E3}]
Version=1
EOF
        unix2dos $gpt_ini

        # scripts.ini
        if ! [ -e $scripts_ini ]; then
            touch $scripts_ini
        fi

        if ! grep -F '[Startup]' $scripts_ini; then
            echo '[Startup]' >>$scripts_ini
        fi

        #  pipefail 
        if num=$(grep -Eo '^[0-9]+' $scripts_ini | sort -n | tail -1 | grep .); then
            num=$((num + 1))
        else
            num=0
        fi

        bats="$bats windows-del-gpo.bat"
        for bat in $bats; do
            echo "${num}CmdLine=%SystemDrive%\\$bat" >>$scripts_ini
            echo "${num}Parameters=" >>$scripts_ini
            num=$((num + 1))
        done
        cat $scripts_ini
        unix2dos $scripts_ini

        # windows-del-gpo.bat
        download $confhome/windows-del-gpo.bat $os_dir/windows-del-gpo.bat
    else
        #  SetupComplete
        setup_complete=$(get_path_in_correct_case $os_dir/Windows/Setup/Scripts/SetupComplete.cmd)
        mkdir -p "$(dirname $setup_complete)"

        #  C:\Setup\Scripts\SetupComplete.cmd 
        # call  bat 
        setup_complete_mod=$(mktemp)
        for bat in $bats; do
            echo "if exist %SystemDrive%\\$bat (call %SystemDrive%\\$bat)" >>$setup_complete_mod
        done

        # 
        if [ -f $setup_complete ]; then
            cat $setup_complete >>$setup_complete_mod
        fi

        unix2dos $setup_complete_mod

        # cat 
        cat $setup_complete_mod >$setup_complete

        # 
        cat -n $setup_complete
    fi
}

get_axx64() {
    case "$(uname -m)" in
    x86_64) echo amd64 ;;
    aarch64) echo arm64 ;;
    esac
}

is_file_or_link() {
    # -e / -f  false
    # -L  true
    [ -f $1 ] || [ -L $1 ]
}

cp_resolv_conf() {
    local os_dir=$1
    if is_file_or_link $os_dir/etc/resolv.conf &&
        ! is_file_or_link $os_dir/etc/resolv.conf.orig; then
        mv $os_dir/etc/resolv.conf $os_dir/etc/resolv.conf.orig
    fi
    cp -f /etc/resolv.conf $os_dir/etc/resolv.conf
}

rm_resolv_conf() {
    local os_dir=$1
    rm -f $os_dir/etc/resolv.conf $os_dir/etc/resolv.conf.orig
}

restore_resolv_conf() {
    local os_dir=$1
    if is_file_or_link $os_dir/etc/resolv.conf.orig; then
        mv -f $os_dir/etc/resolv.conf.orig $os_dir/etc/resolv.conf
    fi
}

keep_now_resolv_conf() {
    local os_dir=$1
    rm -f $os_dir/etc/resolv.conf.orig
}

#  https://github.com/alpinelinux/alpine-conf/blob/3.18.1/setup-disk.in#L421
get_alpine_firmware_pkgs() {
    #  modloop modinfo 
    ensure_service_started modloop >&2

    #  linux-firmware-other
    #  linux-firmware-xxx
    #  firmware linux-firmware-none
    firmware_pkgs=$(
        cd /sys/module && modinfo -F firmware -- * 2>/dev/null |
            awk -F/ '{print $1 == $0 ? "linux-firmware-other" : "linux-firmware-"$1}' |
            sort -u
    )

    #  command  apk  >&2
    retry 5 command apk search --quiet --exact ${firmware_pkgs:-linux-firmware-none}
}

get_ucode_firmware_pkgs() {
    is_virt && return

    case "$distro" in
    centos | almalinux | rocky | oracle | redhat | anolis | opencloudos | openeuler) os=elol ;;
    *) os=$distro ;;
    esac

    case "$os-$(get_cpu_vendor)" in
    # alpine  linux-firmware 
    # setup-alpine  firmwaremodloop 
    # https://github.com/alpinelinux/alpine-conf/blob/3.18.1/setup-disk.in#L421
    alpine-intel) echo intel-ucode ;;
    alpine-amd) echo amd-ucode ;;
    alpine-*) ;;

    debian-intel) echo firmware-linux intel-microcode ;;
    debian-amd) echo firmware-linux amd64-microcode ;;
    debian-*) echo firmware-linux ;;

    ubuntu-intel) echo linux-firmware intel-microcode ;;
    ubuntu-amd) echo linux-firmware amd64-microcode ;;
    ubuntu-*) echo linux-firmware ;;

    #  kernel-firmware kernel-firmware-intel
    opensuse-intel) echo kernel-firmware ucode-intel ;;
    opensuse-amd) echo kernel-firmware ucode-amd ;;
    opensuse-*) echo kernel-firmware ;;

    arch-intel) echo linux-firmware intel-ucode ;;
    arch-amd) echo linux-firmware amd-ucode ;;
    arch-*) echo linux-firmware ;;

    gentoo-intel) echo linux-firmware intel-microcode ;;
    gentoo-amd) echo linux-firmware ;;
    gentoo-*) echo linux-firmware ;;

    nixos-intel) echo linux-firmware microcodeIntel ;;
    nixos-amd) echo linux-firmware microcodeAmd ;;
    nixos-*) echo linux-firmware ;;

    fedora-intel) echo linux-firmware microcode_ctl ;;
    fedora-amd) echo linux-firmware amd-ucode-firmware microcode_ctl ;;
    fedora-*) echo linux-firmware microcode_ctl ;;

    elol-intel) echo linux-firmware microcode_ctl ;;
    elol-amd) echo linux-firmware microcode_ctl ;;
    elol-*) echo linux-firmware microcode_ctl ;;
    esac
}

chroot_systemctl_disable() {
    local os_dir=$1
    shift

    for unit in "$@"; do
        # x(.)  x.service
        if ! [[ "$unit" = "*.*" ]]; then
            unit=$i.service
        fi

        # debian 10  0
        if ! chroot $os_dir systemctl list-unit-files "$unit" 2>&1 | grep -Eq '^0 unit'; then
            chroot $os_dir systemctl disable "$unit"
        fi
    done
}

remove_or_disable_cloud_init() {
    local os_dir=$1

    if ! is_have_cmd_on_disk $os_dir cloud-init; then
        return
    fi

    info "Remove or Disable Cloud-Init"

    # ubuntu-server-minimal ubuntu-cloud-minimal  cloud-init
    #  iso  ubuntu  cloud-init
    #  ubuntu  cloud-init

    # iso  /etc/cloud/cloud.cfg.d/99-installer.cfg 
    #     1.  ssh 
    #     2.  /etc/cloud/cloud-init.disabled

    if grep -iq ubuntu $os_dir/etc/os-release; then
        #  iso  ubuntu cloud-init.disabled
        touch $os_dir/etc/cloud/cloud-init.disabled
    else
        # systemctl is-enabled cloud-init-hotplugd.service  static
        # disable  disable
        for unit in $(
            chroot $os_dir systemctl list-unit-files |
                grep -E '^(cloud-init|cloud-init-.*|cloud-config|cloud-final)\.(service|socket)' | grep enabled | awk '{print $1}'
        ); do
            # 
            if chroot $os_dir systemctl -q is-enabled "$unit"; then
                chroot $os_dir systemctl disable "$unit"
            fi
        done

        for pkg_mgr in dnf yum zypper apt-get; do
            if is_have_cmd_on_disk $os_dir $pkg_mgr; then
                case $pkg_mgr in
                dnf | yum)
                    chroot $os_dir $pkg_mgr remove -y cloud-init
                    rm -f $os_dir/etc/cloud/cloud.cfg.rpmsave
                    ;;
                zypper)
                    #  cloud-init  sudo
                    if ! [ "$username" = root ]; then
                        sed -i '/^sudo$/d' "$os_dir/var/lib/zypp/AutoInstalled"
                    fi
                    #  -u 
                    chroot $os_dir zypper remove -y -u cloud-init cloud-init-config-suse
                    ;;
                apt-get)
                    # ubuntu 25.04  cloud-init-base
                    chroot_apt_remove $os_dir cloud-init cloud-init-base
                    chroot_apt_autoremove $os_dir
                    ;;
                esac
                break
            fi
        done
    fi
}

disable_jeos_firstboot() {
    local os_dir=$1
    info "Disable JeOS Firstboot"

    # 
    # https://github.com/openSUSE/jeos-firstboot?tab=readme-ov-file#usage

    rm -rf $os_dir/var/lib/YaST2/reconfig_system

    for name in jeos-firstboot jeos-firstboot-snapshot; do
        # 
        chroot $os_dir systemctl disable "$name.service" 2>/dev/null || true
    done

    # 
    # chroot $os_dir zypper remove -y -u jeos-firstboot
}

create_network_manager_config() {
    local source_cfg=$1
    local os_dir=$2
    info "Create Network-Manager config"

    #  alpine  cloud-init  Network Manager 
    apk add cloud-init
    cloud-init devel net-convert -p "$source_cfg" -k yaml -d /out -D alpine -O network-manager

    #  ipv6.method=dhcp 
    # https://networkmanager.dev/docs/api/latest/nm-settings-nmcli.html#:~:text=false/no/off-,ipv6,-.method
    sed -i -e '/^may-fail=/d' -e 's/^method=dhcp/method=auto/' \
        /out/etc/NetworkManager/system-connections/cloud-init-eth*.nmconnection

    #  # Generated by cloud-init. Changes will be lost.
    #  org.freedesktop.NetworkManager.origin=cloud-init
    # 
    sed -i \
        -e '/^# Generated by cloud-init/d' \
        -e '/^org\.freedesktop\.NetworkManager\.origin=cloud-init/d' \
        /out/etc/NetworkManager/system-connections/cloud-init-eth*.nmconnection
    del_head_empty_lines_inplace /out/etc/NetworkManager/system-connections/cloud-init-eth*.nmconnection

    cp /out/etc/NetworkManager/system-connections/cloud-init-eth*.nmconnection \
        $os_dir/etc/NetworkManager/system-connections/

    # 
    rm -rf /out
    apk del cloud-init

    # 
    for file in "$os_dir"/etc/NetworkManager/system-connections/cloud-init-eth*.nmconnection; do
        cat -n "$file" >&2
    done
}

modify_linux() {
    local os_dir=$1
    info "Modify Linux"

    find_and_mount() {
        mount_point=$1
        mount_dev=$(awk "\$2==\"$mount_point\" {print \$1}" $os_dir/etc/fstab)
        mount_opts=$(awk "\$2==\"$mount_point\" {print \$4}" $os_dir/etc/fstab)
        if [ -n "$mount_dev" ]; then
            mount -o "$mount_opts" "$mount_dev" "$os_dir$mount_point"
        fi
    }

    #  onlink 
    add_onlink_script_if_need() {
        for ethx in $(get_eths); do
            if is_staticv4 || is_staticv6; then
                fix_sh=cloud-init-fix-onlink.sh
                download "$confhome/$fix_sh" "$os_dir/$fix_sh"
                insert_into_file "$ci_file" after '^runcmd:' <<EOF
  - bash "/$fix_sh" && rm -f "/$fix_sh"
EOF
                break
            fi
        done
    }

    #  centos
    del_exist_sysconfig_NetworkManager_config $os_dir

    #  fedora (el/ol/fork )
    # 1.  selinux kdump
    # 2. +
    if [ -f $os_dir/etc/redhat-release ]; then
        #  cloud-init /  firmware 
        create_swap_if_ram_less_than 2048 $os_dir/swapfile

        mount_pseudo_fs $os_dir

        # find_and_mount /boot
        # find_and_mount /boot/efi
        # fedora  fstab  /home /var mount -a
        #  /home/$username  ssh 
        chroot $os_dir mount -a

        cp_resolv_conf $os_dir

        #  alpine  cloud-init  Network Manager 
        create_cloud_init_network_config /net.cfg
        create_network_manager_config /net.cfg "$os_dir"
        rm /net.cfg

        # TODO: fedora 43 eol 
        #  cloud-init  netcat
        #  netcat 
        #  netcat 
        # >>> Running %preun scriptlet: netcat-0:1.229-3.fc43.x86_64
        # >>> Error in %preun scriptlet: netcat-0:1.229-3.fc43.x86_64
        # >>> Scriptlet output:
        # >>> failed to create admindir: No such file or directory
        # >>> [RPM] %preun(netcat-1.229-3.fc43.x86_64) scriptlet failed, exit status 2
        # >>> [RPM] netcat-1.229-3.fc43.x86_64: erase failed
        if [ "$distro" = fedora ] && [ "$releasever" = 43 ]; then
            chroot $os_dir dnf mark user netcat -y
        fi
        remove_or_disable_cloud_init $os_dir

        disable_selinux $os_dir
        disable_kdump $os_dir

        if fw_pkgs=$(get_ucode_firmware_pkgs) && [ -n "$fw_pkgs" ]; then
            is_have_cmd_on_disk $os_dir dnf && mgr=dnf || mgr=yum
            chroot $os_dir $mgr install -y $fw_pkgs
        fi

        restore_resolv_conf $os_dir
    fi

    # debian
    # 1. EOL 
    # 2. 
    # 3. +
    #  ubuntu  /etc/debian_version
    if [ "$distro" = debian ]; then
        #  onlink 
        # add_onlink_script_if_need

        mount_pseudo_fs $os_dir
        cp_resolv_conf $os_dir
        find_and_mount /boot
        find_and_mount /boot/efi

        remove_or_disable_cloud_init $os_dir

        #  Components, 
        if [ -f $os_dir/etc/apt/sources.list.d/debian.sources ]; then
            comps=$(grep ^Components: $os_dir/etc/apt/sources.list.d/debian.sources | head -1 | cut -d' ' -f2-)
        else
            comps=$(grep '^deb ' $os_dir/etc/apt/sources.list | head -1 | cut -d' ' -f4-)
        fi

        # ELTS/CN 
        if is_elts; then
            # ELTS
            wget https://deb.freexian.com/extended-lts/archive-key.gpg \
                -O $os_dir/etc/apt/trusted.gpg.d/freexian-archive-extended-lts.gpg

            # shellcheck disable=SC1091
            codename=$({ . "$os_dir/etc/os-release" && echo "$VERSION_CODENAME"; })
            if [ -f $os_dir/etc/apt/sources.list.d/debian.sources ]; then
                cat <<EOF >$os_dir/etc/apt/sources.list.d/debian.sources
Types: deb
URIs: http://$deb_mirror
Suites: $codename
Components: $comps
Signed-By: /etc/apt/trusted.gpg.d/freexian-archive-extended-lts.gpg
EOF
            else
                echo "deb http://$deb_mirror $codename $comps" >$os_dir/etc/apt/sources.list
            fi
        else
            # non-ELTS
            if is_in_china; then
                #  security  security.debian.org/debian-security  /etc/apt/mirrors/debian-security.list
                for file in $os_dir/etc/apt/mirrors/debian.list $os_dir/etc/apt/sources.list; do
                    if [ -f "$file" ]; then
                        sed -i "s|deb\.debian\.org/debian|$deb_mirror|" "$file"
                    fi
                done
            fi
        fi

        # 
        pkgs=$(chroot $os_dir apt-mark showmanual linux-image* linux-headers*)
        chroot $os_dir apt-mark auto $pkgs

        # 
        kernel_package=$kernel
        # shellcheck disable=SC2046
        #  cloud 
        if [[ "$kernel_package" = 'linux-image-cloud-*' ]] &&
            ! sh /can_use_cloud_kernel.sh "$xda" $(get_eths); then
            kernel_package=$(echo "$kernel_package" | sed 's/-cloud//')
        fi

        #  apt-mark manual
        chroot_apt_install $os_dir "$kernel_package"

        #  autoremove 
        chroot_apt_autoremove $os_dir

        # +
        if fw_pkgs=$(get_ucode_firmware_pkgs) && [ -n "$fw_pkgs" ]; then
            #  debian 10 11  iucode-tool  contrib 
            #  debian 12  iucode-tool  main 
            [ "$releasever" -ge 12 ] &&
                comps_to_add=non-free-firmware ||
                comps_to_add="contrib non-free"

            if [ -f $os_dir/etc/apt/sources.list.d/debian.sources ]; then
                file=$os_dir/etc/apt/sources.list.d/debian.sources
                search='^[# ]*Components:'
            else
                file=$os_dir/etc/apt/sources.list
                search='^[# ]*deb'
            fi

            for c in $comps_to_add; do
                if ! echo "$comps" | grep -wq "$c"; then
                    sed -Ei "/$search/s/$/ $c/" $file
                fi
            done

            chroot_apt_install $os_dir $fw_pkgs
        fi

        # genericcloud  grub 
        # https://salsa.debian.org/cloud-team/debian-cloud-images/-/tree/master/config_space/bookworm/files/etc/default/grub.d
        rm -f $os_dir/etc/default/grub.d/10_cloud.cfg
        rm -f $os_dir/etc/default/grub.d/15_timeout.cfg
        chroot $os_dir update-grub

        if true; then
            #  nocloud 
            chroot_apt_install $os_dir openssh-server
        else
            #  genericcloud 

            #  key
            # cat $os_dir/usr/share/openssh/sshd_config $os_dir/etc/ssh/sshd_config
            # chroot $os_dir ssh-keygen -A
            rm -rf $os_dir/etc/ssh/sshd_config
            UCF_FORCE_CONFFMISS=1 chroot $os_dir dpkg-reconfigure openssh-server
        fi

        # 
        # debian 11 ifupdown
        # debian 12 netplan + networkd + resolved
        # ifupdown dhcp  24+?

        #  netplan
        if false && is_have_cmd_on_disk $os_dir netplan; then
            chroot_apt_install $os_dir netplan.io
            # 
            chroot $os_dir systemctl disable networking resolvconf 2>/dev/null || true
            chroot $os_dir systemctl enable systemd-networkd systemd-resolved
            rm_resolv_conf $os_dir
            ln -sf ../run/systemd/resolve/stub-resolv.conf $os_dir/etc/resolv.conf
            if [ -f "$os_dir/etc/cloud/cloud.cfg.d/99_fallback.cfg" ]; then
                insert_into_file $os_dir/etc/cloud/cloud.cfg.d/99_fallback.cfg after '#cloud-config' <<EOF
system_info:
  network:
    renderers: [netplan]
    activators: [netplan]
EOF
            fi
        fi

        create_ifupdown_config $os_dir/etc/network/interfaces

        # ifupdown  rdnss
        #  iso  rdnssd rdnss  resolv.conf
        if false; then
            chroot_apt_install $os_dir rdnssd
        fi

        # debian 10 11  resolvconf
        # debian 12  netplan systemd-resolved
        #  cloud-init 
        #  iso  ifupdown

        # 
        chroot $os_dir systemctl disable resolvconf systemd-networkd systemd-resolved 2>/dev/null || true

        chroot_apt_install $os_dir ifupdown
        chroot_apt_remove $os_dir resolvconf netplan.io systemd-resolved
        chroot_apt_autoremove $os_dir
        chroot $os_dir systemctl enable networking

        #  networking  /etc/network/interfaces  resolv.conf
        #  isc-dhcp-client  resolv.conf
        #  debian iso  rdnssd
        keep_now_resolv_conf $os_dir
    fi

    # opensuse
    # 1. kernel-default-base  nvme gve mlx5 mana  kernel-default
    # 2. +
    # https://documentation.suse.com/smart/virtualization-cloud/html/minimal-vm/index.html
    if grep -q opensuse $os_dir/etc/os-release; then
        create_swap_if_ram_less_than 1024 $os_dir/swapfile
        mount_pseudo_fs $os_dir
        cp_resolv_conf $os_dir
        find_and_mount /boot
        find_and_mount /boot/efi

        disable_jeos_firstboot $os_dir

        #  selinux
        disable_selinux $os_dir

        # opensuse leap 16.0 / tumbleweed  NetworkManager
        #  alpine  cloud-init  Network Manager 
        create_cloud_init_network_config /net.cfg
        create_network_manager_config /net.cfg "$os_dir"
        rm /net.cfg

        # 
        #  leap  kernel-azure
        if grep -iq leap $os_dir/etc/os-release && [ "$(get_cloud_vendor)" = azure ]; then
            target_kernel='kernel-azure'
        else
            target_kernel='kernel-default'
        fi

        # rpm -qi 
        origin_kernel=$(chroot $os_dir rpm -qa 'kernel-*' --qf '%{NAME}\n' | grep -v firmware)
        if ! [ "$(echo "$origin_kernel" | wc -l)" -eq 1 ]; then
            error_and_exit "Unexpected kernel installed: $origin_kernel"
        fi

        # 16.0  kernel-default-base  kernel-default
        # tw  kernel-default-base  kernel-default
        #  --force-resolution  kernel-default-base
        if ! [ "$origin_kernel" = "$target_kernel" ]; then
            # x86 arm 
            # Failed to get root password hash
            # Failed to import /etc/uefi/certs/76B6A6A0.crt
            # warning: %post(kernel-default-5.14.21-150500.55.83.1.x86_64) scriptlet failed, exit status 255
            need_password_workaround=false
            if grep -q '^root:[:!*]' $os_dir/etc/shadow; then
                need_password_workaround=true
            fi

            if $need_password_workaround; then
                echo "root:$(mkpasswd '')" | chroot $os_dir chpasswd -e
            fi
            # 
            chroot $os_dir zypper install -y --force-resolution $target_kernel
            # 
            if chroot $os_dir rpm -q $origin_kernel; then
                chroot $os_dir zypper remove -y --force-resolution $origin_kernel
            fi
            if $need_password_workaround; then
                chroot $os_dir passwd -d -l root
            fi
        fi

        # +
        if fw_pkgs=$(get_ucode_firmware_pkgs) && [ -n "$fw_pkgs" ]; then
            chroot $os_dir zypper install -y $fw_pkgs
        fi

        #  cloud-init
        #  sysconfig  cloud-init
        remove_or_disable_cloud_init $os_dir

        restore_resolv_conf $os_dir
    fi

    # arch 
    if false && [ -f $os_dir/etc/arch-release ]; then
        #  onlink 
        add_onlink_script_if_need

        # 
        cp_resolv_conf $os_dir
        mount_pseudo_fs $os_dir
        chroot $os_dir pacman-key --init
        chroot $os_dir pacman-key --populate
        rm_resolv_conf $os_dir
    fi

    # gentoo 
    if false && [ -f $os_dir/etc/gentoo-release ]; then
        # 
        mount_pseudo_fs $os_dir
        cp_resolv_conf $os_dir

        # cloud-init
        is_password_plaintext && sed -i 's/enforce=everyone/enforce=none/' $os_dir/etc/security/passwdqc.conf
        change_user_password $os_dir
        is_password_plaintext && sed -i 's/enforce=none/enforce=everyone/' $os_dir/etc/security/passwdqc.conf

        #  profile
        # https://github.com/gentoo/gentoo/blob/master/profiles/profiles.desc
        chroot $os_dir emerge-webrsync
        profile=$(chroot $os_dir eselect profile list | grep stable | grep systemd |
            awk '{print length($2), $2}' | sort -n | head -1 | awk '{print $2}')
        chroot $os_dir eselect profile set $profile

        #  resolv.conf systemd-resolved 
        rm_resolv_conf $os_dir

        # 
        chroot $os_dir systemctl enable systemd-networkd
        chroot $os_dir systemctl enable systemd-resolved

        # systemd-networkd 
        # https://bugs.gentoo.org/910404 
        # https://github.com/systemd/systemd/issues/27718#issuecomment-1564877478
        #  networkctlsystemd-networkd
        insert_into_file $os_dir/lib/systemd/system/systemd-logind.service after '\[Service\]' <<EOF
ExecStartPost=-networkctl
EOF

        #  cloud-init.disabled networkd 
        #  ens3  eth0
        #  networkd 
        insert_into_file $ci_file after '^runcmd:' <<EOF
  - sed -i '/^Name=/d' /etc/systemd/network/10-cloud-init-eth*.network
EOF

        #  onlink 
        add_onlink_script_if_need
    fi

    basic_init $os_dir

    #  basic_init 
    #  cloud-init

    #  cloud-init 
    if [ -f "$ci_file" ]; then
        cat -n "$ci_file"
    fi

    #  swap
    swapoff -a
    rm -f $os_dir/swapfile
}

setup_nocloud() {
    local os_dir=$1
    info "Setup NoCloud"

    # 1.  NoCloud-only datasource
    mkdir -p "$os_dir/etc/cloud/cloud.cfg.d"
    cat >"$os_dir/etc/cloud/cloud.cfg.d/99-datasource.cfg" <<'EOF'
datasource_list: [ NoCloud, None ]
datasource:
  NoCloud:
    seedfrom: /var/lib/cloud/seed/nocloud/
    fs_label: null
EOF

    # 2.  seed  host  initrd 
    mkdir -p "$os_dir/var/lib/cloud/seed/nocloud"
    cp /configs/cloud-data/* "$os_dir/var/lib/cloud/seed/nocloud/"

    # 3.  cloud-init 
    rm -f "$os_dir/etc/cloud/cloud-init.disabled"

    # 4.  cloud-init 
    rm -rf "$os_dir/var/lib/cloud/instance"
    rm -rf "$os_dir/var/lib/cloud/instances"
}

# cache22 fork: after a ghcr DD image is written, inject the requested SSH
# key into the ostree deployment's home subvol so the box is reachable
# headless on first boot. The image's own first-boot service grows the
# filesystem, so nothing else is needed here.
cache22_inject_ssh_key() {
    case "$img" in ghcr://*) ;; *) return 0 ;; esac
    [ -s /configs/ssh_keys ] || return 0
    info "cache22: injecting SSH key into ostree deployment"
    apk add btrfs-progs >/dev/null 2>&1 || true
    modprobe btrfs 2>/dev/null || true
    update_part
    c22_root=$(blkid -t LABEL=cache22-root -o device 2>/dev/null | head -1)
    [ -n "$c22_root" ] || c22_root=$(ls /dev/${xda}3 /dev/${xda}p3 2>/dev/null | head -1)
    [ -b "$c22_root" ] || { warn "cache22: cache22-root not found; skipping key inject"; return 0; }
    mkdir -p /c22home
    if ! mount -o subvol=home "$c22_root" /c22home; then
        warn "cache22: could not mount home subvol; skipping key inject"
        return 0
    fi
    install -d -m 0700 /c22home/cache/.ssh
    cat /configs/ssh_keys >>/c22home/cache/.ssh/authorized_keys
    chmod 0600 /c22home/cache/.ssh/authorized_keys
    chown -R 1000:1000 /c22home/cache/.ssh
    umount /c22home

    # The image ships the cache password expired (for the console flow's
    # forced change). An expired password forces a change even on SSH key
    # login via PAM, which would break headless key access. Since a key is
    # being injected, clear the expiry so key login is clean.
    mkdir -p /c22root
    if mount -o subvol=root "$c22_root" /c22root; then
        c22_etc=$(find /c22root/ostree/deploy -mindepth 3 -maxdepth 3 -type d -name '*.0' ! -path '*/backing/*' 2>/dev/null | head -1)/etc
        if [ -f "$c22_etc/shadow" ]; then
            c22_days=$(( $(date +%s) / 86400 ))
            sed -i "s/^\(cache:[^:]*\):0:/\1:${c22_days}:/" "$c22_etc/shadow"
        fi
        # Also key root: /root is a symlink to /var/roothome, which lives in
        # the stateroot var. PermitRootLogin=prohibit-password lets root in
        # by key only.
        c22_rh=$(ls -d /c22root/ostree/deploy/*/var/roothome 2>/dev/null | head -1)
        [ -n "$c22_rh" ] || { c22_var=$(ls -d /c22root/ostree/deploy/*/var 2>/dev/null | head -1); c22_rh="$c22_var/roothome"; }
        if [ -n "$c22_rh" ]; then
            install -d -m 0700 "$c22_rh/.ssh"
            cat /configs/ssh_keys >>"$c22_rh/.ssh/authorized_keys"
            chmod 0600 "$c22_rh/.ssh/authorized_keys"
            chown -R 0:0 "$c22_rh/.ssh"
        fi
        umount /c22root
    fi
    info "cache22: SSH key injected for users 'cache' and 'root'"
}

# Place an Ignition config on a freshly written disk. This is what lets an
# Ignition-provisioned distro be installed unattended by dd: Fedora CoreOS
# reads ignition/config.ign from the partition labelled 'boot', Flatcar reads
# config.ign from the partition labelled 'OEM'.
fcos_inject_ignition() {
    [ -s /configs/ignition.json ] || return 0

    modprobe ext4 2>/dev/null || true
    update_part

    ign_part=
    ign_dest=
    ign_boot=$(blkid -t LABEL=boot -o device 2>/dev/null | head -1)
    ign_oem=$(blkid -t LABEL=OEM -o device 2>/dev/null | head -1)

    mkdir -p /ignmnt
    if [ -b "$ign_boot" ] && mount "$ign_boot" /ignmnt 2>/dev/null; then
        # The pristine Fedora CoreOS image ships this marker, and it is what
        # tells GRUB to run Ignition on first boot. Without it the config
        # would be written and then never read.
        if [ -f /ignmnt/ignition.firstboot ]; then
            ign_part=$ign_boot
            ign_dest=ignition/config.ign
        else
            umount /ignmnt
        fi
    fi
    if [ -z "$ign_part" ] && [ -b "$ign_oem" ] && mount "$ign_oem" /ignmnt 2>/dev/null; then
        ign_part=$ign_oem
        ign_dest=config.ign
    fi

    if [ -z "$ign_part" ]; then
        warn "ignition: no Ignition-provisioned disk found; config not applied"
        return 0
    fi

    mkdir -p "/ignmnt/$(dirname "$ign_dest")"
    cat /configs/ignition.json >"/ignmnt/$ign_dest"
    chmod 0600 "/ignmnt/$ign_dest"
    umount /ignmnt
    sync
    info "ignition: config written to $ign_part /$ign_dest"
}

modify_os_on_disk() {
    only_process=$1
    info "Modify disk if is $only_process"

    update_part

    # dd linux nocloud 
    if [ "$distro" = "dd" ] && [ "$only_process" != "nocloud" ] && ! lsblk -f /dev/$xda | grep ntfs; then
        cache22_inject_ssh_key
        fcos_inject_ignition
        return
    fi

    mkdir -p /os
    # 
    # lsblk /dev/mmcblk0*  mmcblk0boot0 mmcblk0boot1
    # lsblk /dev/mmcblk0   mmcblk0boot0 mmcblk0boot1
    for part in $(lsblk /dev/$xda --filter 'TYPE == "part"' --sort SIZE -no NAME | tac); do
        # btrfs
        # fedora root
        if mount -o ro /dev/$part /os; then
            if [ "$only_process" = linux ] || [ "$only_process" = nocloud ]; then
                if etc_dir=$({ ls -d /os/etc/ || ls -d /os/*/etc/; } 2>/dev/null); then
                    local os_dir
                    os_dir=$(dirname $etc_dir)
                    # 
                    mount -o remount,rw /os
                    if [ "$only_process" = nocloud ]; then
                        setup_nocloud $os_dir
                    else
                        modify_linux $os_dir
                    fi
                    return
                fi
            elif [ "$only_process" = windows ]; then
                # find 
                # find /mnt/c -iname windows -type d -maxdepth 1
                # find: /mnt/c/pagefile.sys: Permission denied
                # find: /mnt/c/swapfile.sys: Permission denied
                # shellcheck disable=SC1090
                # find_file_ignore_case 
                . <(wget -O- $confhome/windows-driver-utils.sh)
                if find_file_ignore_case /os/Windows/System32/ntoskrnl.exe >/dev/null 2>&1; then
                    # 
                    is_windows() { true; }
                    # 
                    umount /os
                    if ! { mount -t ntfs3 -o nocase,rw /dev/$part /os &&
                        mount | grep -w 'on /os type' | grep -wq rw; }; then
                        # 
                        warn "Can't normally mount windows partition /dev/$part as rw."
                        dmesg | grep -F "ntfs3($part):" || true
                        #  fallback  ro, 
                        if mount | grep -wq 'on /os type'; then
                            umount /os
                        fi
                        # 
                        apk add ntfs-3g-progs
                        ntfsfix /dev/$part
                        apk del ntfs-3g-progs
                        mount -t ntfs3 -o nocase,rw,force /dev/$part /os
                    fi
                    # 
                    get_windows_version_from_windows_drive /os
                    modify_windows /os
                    return
                fi
            fi
            umount /os
        fi
    done
    error_and_exit "Can't find os partition."
}

get_need_swap_size() {
    need_ram=$1
    phy_ram=$(get_approximate_ram_size)

    if [ $need_ram -gt $phy_ram ]; then
        echo $((need_ram - phy_ram))
    else
        echo 0
    fi
}

create_swap_if_ram_less_than() {
    need_ram=$1
    swapfile=$2

    swapsize=$(get_need_swap_size $need_ram)
    if [ $swapsize -gt 0 ]; then
        create_swap $swapsize $swapfile
    fi
}

create_swap() {
    swapsize=$1
    swapfile=$2

    if ! grep $swapfile /proc/swaps; then
        #  btrfs  swapfile
        truncate -s 0 $swapfile
        #  chattr +C  0
        chattr +C $swapfile 2>/dev/null
        fallocate -l ${swapsize}M $swapfile
        chmod 0600 $swapfile
        mkswap $swapfile
        swapon $swapfile
    fi
}

del_user_password_and_lock() {
    local os_dir=$1
    local username=$2

    #  ssh 
    # alpine ×
    #  √

    # root  root su - root  root
    # alpine ×
    #  √

    # centos 7  -d -l
    # passwd: Only one of -l, -u, -d, -S may be specified.

    # 
    chroot "$os_dir" passwd -d "$username"

    # 
    if ! [ -e "$os_dir/etc/alpine-release" ]; then
        chroot "$os_dir" passwd -l "$username"
    fi

    # alpine  ssh
    #  alpine  pam
    # 

    #  pam  ssh
    #  pam 

    # alpine  openssh-server-pam  pam
    #  UsePAM yes  UsePAM yes
    # localhost:~# sshd -G | grep -i pam
    # /etc/ssh/sshd_config line 88: Unsupported option UsePAM
}

set_ssh_keys_and_del_password() {
    local os_dir=$1

    info 'set ssh keys'

    if [ "$username" = root ]; then
        local user_home="/root"
    else
        local user_home="/home/$username"
    fi

    # 
    if true; then
        (
            umask 077
            mkdir -p "$os_dir/$user_home/.ssh"
            cat /configs/ssh_keys >"$os_dir/$user_home/.ssh/authorized_keys"
        )
        #  chroot uid/gid  alpine live os  uid/gid
        chroot "$os_dir" chown "$username:$username" "$user_home"
        chroot "$os_dir" chown "$username:$username" "$user_home/.ssh"
        chroot "$os_dir" chown "$username:$username" "$user_home/.ssh/authorized_keys"
    else
        (
            #  bsd  chroot 
            umask 077
            read -r owner group < \
                <(awk -F: -v user="$username" '$1==user {print $3,$4}' "$os_dir/etc/passwd")
            install -D \
                -m 600 \
                -o "$owner" \
                -g "$group" \
                /configs/ssh_keys \
                "$os_dir/$user_home/.ssh/authorized_keys"
        )
    fi

    # /
    del_user_password_and_lock "$os_dir" "$username"

    # debian  /etc/shadow  root 
    # root:!unprovisioned:20591:0:99999:7:::
    #  root  ssh 
    #  root 
    if ! [ "$username" = root ] && is_have_cmd_on_disk "$os_dir" systemd-firstboot; then
        del_user_password_and_lock "$os_dir" root
    fi
}

_is_ssh_kv_effective() {
    local os_dir=$1
    local key=$2
    local value=$3

    #  ubuntu 22.04 
    # Missing privilege separation directory: /run/sshd
    if [ -d "$os_dir/run/sshd" ]; then
        we_create_run_sshd_dir=false
    else
        we_create_run_sshd_dir=true
        mkdir -p "$os_dir/run/sshd"
    fi

    # centos 7 / ubuntu 22.04  -G
    if res=$(chroot "$os_dir" sshd -G 2>/dev/null || chroot "$os_dir" sshd -T 2>/dev/null); then
        # 
        if $we_create_run_sshd_dir; then
            rm -rf "$os_dir/run/sshd"
        fi
        printf "%s\n" "$res" | grep -Fxiq "$key $value"
    else
        error_and_exit "Failed to verify sshd config."
    fi
}

is_ssh_kv_effective() {
    local os_dir=$1
    local key=$2
    local value=$3

    if _is_ssh_kv_effective "$os_dir" "$key" "$value"; then
        return 0
    fi

    # centos 7  prohibit-password sshd -T  without-password
    if [ "$(echo "$key" | to_lower)" = "permitrootlogin" ] && {
        [ "$(echo "$value" | to_lower)" = "prohibit-password" ] ||
            [ "$(echo "$value" | to_lower)" = "without-password" ]
    }; then
        if _is_ssh_kv_effective "$os_dir" "permitrootlogin" "prohibit-password" ||
            _is_ssh_kv_effective "$os_dir" "permitrootlogin" "without-password"; then
            return 0
        fi
    fi

    return 1
}

change_ssh_conf_if_different() {
    local os_dir=$1
    local key=$2
    local value=$3
    local sub_conf=$4
    if [ -z "$sub_conf" ]; then
        sub_conf=$(echo "01-$key.conf" | to_lower)
    fi

    # 
    # ubuntu:
    # cat /etc/ssh/sshd_config.d/60-cloudimg-settings.conf | grep -i PasswordAuthentication
    # PasswordAuthentication no

    # gentoo:
    # cat /etc/ssh/sshd_config.d/9999999gentoo-pam.conf | grep -i PasswordAuthentication
    # PasswordAuthentication no

    # 0. 
    if is_ssh_kv_effective "$os_dir" "$key" "$value"; then
        return
    fi

    if line="^$key .*" && grep -Exiq "$line" $os_dir/etc/ssh/sshd_config 2>/dev/null; then
        # 1.  sshd_config  key
        sed -Ei "s/$line/$key $value/" $os_dir/etc/ssh/sshd_config
    elif include_line='^Include .*/etc/ssh/sshd_config.d' &&
        # 2.  sshd_config  sshd_config.d
        #     sshd_config.d/01-xxx.conf

        # arch  /etc/ssh/sshd_config.d/ 
        # opensuse tumbleweed  /etc/ssh/sshd_config
        #                        /etc/ssh/sshd_config.d/ 
        #                        /usr/etc/ssh/sshd_config
        { grep -iq "$include_line" $os_dir/etc/ssh/sshd_config ||
            grep -iq "$include_line" $os_dir/usr/etc/ssh/sshd_config; } 2>/dev/null; then
        mkdir -p $os_dir/etc/ssh/sshd_config.d/
        echo "$key $value" >"$os_dir/etc/ssh/sshd_config.d/$sub_conf"
    else
        # 3.  sshd_config
        #     sshd_config  key ()
        #    
        line="^[# ]*$key .*"
        if grep -Exiq "$line" $os_dir/etc/ssh/sshd_config; then
            sed -Ei "s/$line/$key $value/" $os_dir/etc/ssh/sshd_config
        else
            echo "$key $value" >>$os_dir/etc/ssh/sshd_config
        fi
    fi

    # 
    if ! is_ssh_kv_effective "$os_dir" "$key" "$value"; then
        error_and_exit "Failed to set sshd config $key $value."
    fi
}

change_ssh_conf_for_key_login() {
    local os_dir=$1

    change_ssh_conf_if_different "$os_dir" PasswordAuthentication no

    # centos 7 PermitRootLogin  yes prohibit-password
    if [ "$username" = root ]; then
        change_ssh_conf_if_different "$os_dir" PermitRootLogin prohibit-password
    fi
}

change_ssh_conf_for_password_login() {
    local os_dir=$1

    # opensuse 16/tumbleweed  openssh-server-config-rootlogin
    #  /usr/etc/ssh/sshd_config.d/50-permit-root-login.conf
    # 
    # 
    if false &&
        [ -f $os_dir/etc/os-release ] &&
        grep -iq opensuse $os_dir/etc/os-release; then
        chroot $os_dir zypper install -y openssh-server-config-rootlogin
    fi

    # PasswordAuthentication  yes
    #  sshd_config.d  PasswordAuthentication no
    change_ssh_conf_if_different "$os_dir" PasswordAuthentication yes

    if [ "$username" = root ]; then
        change_ssh_conf_if_different "$os_dir" PermitRootLogin yes
    fi
}

change_ssh_port() {
    local os_dir=$1
    local ssh_port=$2

    change_ssh_conf_if_different "$os_dir" Port "$ssh_port"
}

# 
add_user_if_need_for_alpine() {
    local os_dir=$1

    if ! grep -q "^$username:" "$os_dir/etc/passwd"; then
        #  -a  Create admin user. Add to wheel group and set up doas
        #  -u  Unlock the user automatically (eg. creating the user non-interactively
        #      with an ssh key for login)
        if is_need_set_ssh_keys; then
            chroot "$os_dir" setup-user -a -u -k "$(cat /configs/ssh_keys)" "$username"
        else
            chroot "$os_dir" setup-user -a -u "$username"
            change_user_password $os_dir
        fi
    fi
}

add_user_if_need() {
    local os_dir=$1

    # 
    if ! grep -q "^$username:" "$os_dir/etc/passwd"; then
        # debian  adduser  useradd
        # https://manpages.debian.org/trixie/passwd/useradd.8.en.html
        # useradd is a low level utility for adding users.
        # On Debian, administrators should usually use adduser(8) instead.

        # adduser  /etc/adduser.conf 
        # 

        # alpine
        if is_have_cmd_on_disk "$os_dir" adduser &&
            chroot "$os_dir" adduser --help 2>&1 | grep -Fq -- BusyBox; then
            chroot "$os_dir" adduser --disabled-password "$username"

        # debian/ubuntu
        elif is_have_cmd_on_disk "$os_dir" adduser &&
            chroot "$os_dir" adduser --help 2>&1 | grep -Fq -- '--disabled-password'; then
            chroot "$os_dir" adduser --disabled-password --comment '' "$username"

        # el
        elif is_have_cmd_on_disk "$os_dir" adduser &&
            chroot "$os_dir" adduser --help 2>&1 | grep -Fq -- '--password'; then
            chroot "$os_dir" adduser --password ! "$username"

        # arch/gentoo  adduser
        else
            chroot "$os_dir" useradd -m "$username"
        fi
    fi

    #  wheel/sudo 
    if ! [ "$username" = root ]; then
        if [ -e "$os_dir/etc/alpine-release" ]; then
            # alpine
            # https://github.com/alpinelinux/alpine-conf/blob/master/setup-user.in#L168

            #  doas
            chroot "$os_dir" apk add doas doas-sudo-shim
            mkdir -p "$os_dir/etc/doas.d"

            # 
            chroot "$os_dir" addgroup "$username" wheel

            # doas:  wheel 
            local file="$os_dir/etc/doas.d/20-wheel.conf"
            local content="permit persist :wheel"
            if ! grep -q "^$content" "$file" 2>/dev/null; then
                echo "$content" >>"$file"
            fi

            # doas:  nopass
            echo "permit nopass $username" >"$os_dir/etc/doas.d/99-$username.conf"
        else
            #  wheel 
            # debian/ubuntu  wheel  sudo 

            # aws lightsail 
            # debian       admin : admin adm dialout cdrom floppy sudo audio dip video plugdev
            # ubuntu       ubuntu : ubuntu adm cdrom sudo dip lxd
            # almalinux    ec2-user : ec2-user adm systemd-journal
            # opensuse     ec2-user : ec2-user

            # 
            for group in \
                wheel sudo \
                adm dialout cdrom floppy audio dip video plugdev lxd systemd-journal; do
                if grep -q "^$group:" "$os_dir/etc/group"; then
                    # chroot "$os_dir" addgroup "$username" "$group"
                    chroot "$os_dir" usermod -aG "$group" "$username"
                fi
            done

            # sudo: gentoo  sudo  /etc/sudoers.d
            if ! [ -d "$os_dir/etc/sudoers.d" ]; then
                install -d -m 0750 "$os_dir/etc/sudoers.d"
            fi

            # sudo:  NOPASSWD
            # https://wiki.archlinux.org/title/Sudo#Sudoers_default_file_permissions
            local file="$os_dir/etc/sudoers.d/99-$username"
            printf '%s\n' "$username ALL=(ALL) NOPASSWD:ALL" >"$file"
            chmod 0440 "$file"
        fi
    fi
}

change_user_password() {
    local os_dir=$1

    info 'change user password'

    if is_password_plaintext; then
        pam_d=$os_dir/etc/pam.d

        [ -f $pam_d/chpasswd ] && has_pamd_chpasswd=true || has_pamd_chpasswd=false

        if $has_pamd_chpasswd; then
            cp $pam_d/chpasswd $pam_d/chpasswd.orig

            # cat /etc/pam.d/chpasswd
            # @include common-password

            # cat /etc/pam.d/chpasswd
            # #%PAM-1.0
            # auth       include      system-auth
            # account    include      system-auth
            # password   substack     system-auth
            # -password   optional    pam_gnome_keyring.so use_authtok
            # password   substack     postlogin

            #  /etc/pam.d/chpasswd  /etc/pam.d/system-auth  /etc/pam.d/system-auth
            #  password  pam_unix.so  use_authtok /etc/pam.d/chpasswd
            files=$(grep -E '^(password|@include)' $pam_d/chpasswd | awk '{print $NF}' | sort -u)
            for file in $files; do
                if [ -f "$pam_d/$file" ] && line=$(grep ^password "$pam_d/$file" | grep -F pam_unix.so); then
                    echo "$line" | sed 's/use_authtok//' >$pam_d/chpasswd
                    break
                fi
            done
        fi

        # 
        plaintext=$(get_password_plaintext)
        printf '%s\n' "$username:$plaintext" | chroot $os_dir chpasswd

        if $has_pamd_chpasswd; then
            mv $pam_d/chpasswd.orig $pam_d/chpasswd
        fi
    else
        printf '%s\n' "$username:$(get_password_linux_sha512)" | chroot $os_dir chpasswd -e
    fi
}

disable_selinux() {
    local os_dir=$1

    # https://access.redhat.com/solutions/3176
    # centos7  selinux  cmdline
    # grep selinux=0 /usr/lib/dracut/modules.d/98selinux/selinux-loadpolicy.sh
    #     warn "To disable selinux, add selinux=0 to the kernel command line."
    if [ -f $os_dir/etc/selinux/config ]; then
        sed -i 's/^SELINUX=enforcing/SELINUX=disabled/g' $os_dir/etc/selinux/config
    fi

    # opensuse  grubby
    if is_have_cmd_on_disk $os_dir grubby; then
        # grubby  GRUB_CMDLINE_LINUX GRUB_CMDLINE_LINUX_DEFAULT
        # rocky  GRUB_CMDLINE_LINUX_DEFAULT  crashkernel=auto
        chroot $os_dir grubby --update-kernel ALL --args selinux=0

        # el7  grubby  /etc/default/grub
        sed -i 's/selinux=1/selinux=0/' $os_dir/etc/default/grub
    else
        #  selinux 
        # sed -Ei 's/[[:space:]]?(security|selinux|enforcing)=[^ ]*//g' $os_dir/etc/default/grub
        sed -i 's/selinux=1/selinux=0/' $os_dir/etc/default/grub

        #  snapshot  transactional-update grub.cfg
        chroot $os_dir grub2-mkconfig -o /boot/grub2/grub.cfg
    fi
}

disable_kdump() {
    local os_dir=$1

    # grubby  GRUB_CMDLINE_LINUX GRUB_CMDLINE_LINUX_DEFAULT
    # rocky  GRUB_CMDLINE_LINUX_DEFAULT  crashkernel=auto

    #  crashkernel bug
    # https://forums.rockylinux.org/t/how-do-i-remove-crashkernel-from-cmdline/13346
    # 
    # yum remove --oldinstallonly   # 
    # rm -rf /boot/loader/entries/* # 
    # yum reinstall kernel-core     # 
    # cat /boot/loader/entries/*    #  crashkernel=1G-4G:192M,4G-64G:256M,64G-:512M

    chroot $os_dir grubby --update-kernel ALL --args crashkernel=no
    # el7  grubby  /etc/default/grub
    sed -i 's/crashkernel=[^ "]*/crashkernel=no/' $os_dir/etc/default/grub
    if chroot $os_dir systemctl -q is-enabled kdump; then
        chroot $os_dir systemctl disable kdump
    fi
}

download_qcow() {
    apk add qemu-img
    info "Download qcow2 image"

    mkdir -p /installer
    mount /dev/disk/by-label/installer /installer

    qcow_file=/installer/cloud_image.qcow2
    if [ -n "$img_type_warp" ]; then
        # 
        #  wget 
        apk add wget
        wget $img -O- | pipe_extract >$qcow_file
    else
        # 
        download "$img" "$qcow_file"
    fi
}

connect_qcow() {
    modprobe nbd nbds_max=1
    qemu-nbd -c /dev/nbd0 $qcow_file

    # 
    # https://github.com/canonical/cloud-utils/blob/main/bin/mount-image-callback
    while ! blkid /dev/nbd0; do
        echo "Waiting for qcow file to be mounted..."
        sleep 5
    done
}

disconnect_qcow() {
    if [ -f /sys/block/nbd0/pid ]; then
        qemu-nbd -d /dev/nbd0

        # 
        while fuser -sm $qcow_file; do
            echo "Waiting for qcow file to be unmounted..."
            sleep 5
        done
    fi
}

get_part_size_mb_for_file_size_b() {
    local file_b=$1
    local file_mb=$((file_b / 1024 / 1024))

    # ext4 
    #        
    #  100 MiB      86 MiB   86.0%
    #  200 MiB     177 MiB   88.5%
    #  500 MiB     454 MiB   90.8%
    #  512 MiB     476 MiB   92.9%
    # 1024 MiB     957 MiB   93.4%
    # 2000 MiB    1914 MiB   95.7%
    # 2048 MiB    1929 MiB   94.1% 
    # 5120 MiB    4938 MiB   96.4%

    #  5% 

    #  1929M  2031M 
    #  2048M  1929M 
    #  150M  150M
    local reserve_mb=$((file_mb * 100 / 95 - file_mb))
    if [ $reserve_mb -lt 150 ]; then
        reserve_mb=150
    fi

    part_mb=$((file_mb + reserve_mb))
    echo "File size:      $file_mb MiB" >&2
    echo "Part size need: $part_mb MiB" >&2
    echo $part_mb
}

get_cloud_image_part_size() {
    # 7
    # https://cloud.centos.org/centos/7/images/CentOS-7-x86_64-GenericCloud-2211.qcow2c 400m

    # 8
    # https://repo.almalinux.org/almalinux/8/cloud/x86_64/images/AlmaLinux-8-GenericCloud-latest.x86_64.qcow2 600m
    # https://download.rockylinux.org/pub/rocky/8/images/x86_64/Rocky-8-GenericCloud-Base.latest.x86_64.qcow2 1.8g
    # https://yum.oracle.com/templates/OracleLinux/OL8/u9/x86_64/OL8U9_x86_64-kvm-b219.qcow2 1g
    # https://rhel-8.10-x86_64-kvm.qcow2 1g

    # 9
    # https://cloud.centos.org/centos/9-stream/x86_64/images/CentOS-Stream-GenericCloud-9-latest.x86_64.qcow2 1.2g
    # https://repo.almalinux.org/almalinux/9/cloud/x86_64/images/AlmaLinux-9-GenericCloud-latest.x86_64.qcow2 600m
    # https://download.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2 600m
    # https://yum.oracle.com/templates/OracleLinux/OL9/u3/x86_64/OL9U3_x86_64-kvm-b220.qcow2 600m
    # https://rhel-9.4-x86_64-kvm.qcow2 900m

    # 10
    # https://cloud.centos.org/centos/10-stream/x86_64/images/CentOS-Stream-GenericCloud-10-latest.x86_64.qcow2 900m

    # https://dl-cdn.alpinelinux.org/alpine/v3.19/releases/cloud/nocloud_alpine-3.19.1-x86_64-uefi-cloudinit-r0.qcow2 200m
    # https://kali.download/cloud-images/current/kali-linux-2024.1-cloud-genericcloud-amd64.tar.xz 200m
    # https://download.opensuse.org/tumbleweed/appliances/openSUSE-Tumbleweed-Minimal-VM.x86_64-Cloud.qcow2 300m
    # https://download.opensuse.org/distribution/leap/15.5/appliances/openSUSE-Leap-15.5-Minimal-VM.aarch64-Cloud.qcow2 300m
    # https://mirror.fcix.net/fedora/linux/releases/40/Cloud/x86_64/images/Fedora-Cloud-Base-Generic.x86_64-40-1.14.qcow2 400m
    # https://geo.mirror.pkgbuild.com/images/latest/Arch-Linux-x86_64-cloudimg.qcow2 500m
    # https://cloud.debian.org/images/cloud/bookworm/latest/debian-12-generic-amd64.qcow2 500m
    # https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img 500m
    # https://gentoo.osuosl.org/experimental/amd64/openstack/gentoo-openstack-amd64-systemd-latest.qcow2 800m

    # openeuler  .qcow2.xz qcow2 
    if [ "$distro" = openeuler ]; then
        # openeuler 20.03 3g
        if [ "$releasever" = 20.03 ]; then
            echo 3GiB
        else
            echo 2GiB
        fi
    elif size_bytes=$(get_http_file_size "$img"); then
        #  btrfs  qcow2  1M
        echo "$(get_part_size_mb_for_file_size_b $size_bytes)MiB"
    else
        # 
        echo "Could not get cloud image size in http response." >&2
        echo 2GiB
    fi
}

chroot_dnf() {
    if is_have_cmd_on_disk /os/ dnf; then
        chroot /os/ dnf -y "$@"
    else
        chroot /os/ yum -y "$@"
    fi
}

chroot_apt_update() {
    local os_dir=$1

    current_hash=$(cat $os_dir/etc/apt/sources.list $os_dir/etc/apt/sources.list.d/*.sources 2>/dev/null | md5sum)
    if ! [ "$saved_hash" = "$current_hash" ]; then
        chroot $os_dir apt-get update
        saved_hash="$current_hash"
    fi
}

chroot_apt_install() {
    local os_dir=$1
    shift

    # 
    # 
    local pkg='' pkgs=''
    for pkg in "$@"; do
        if chroot $os_dir dpkg -s "$pkg" >/dev/null 2>&1; then
            #  manual autoremove 
            chroot $os_dir apt-mark manual "$pkg"
        else
            pkgs="$pkgs $pkg"
        fi
    done

    #  update-initramfs
    if [ -n "$pkgs" ]; then
        chroot_apt_update $os_dir
        DEBIAN_FRONTEND=noninteractive chroot $os_dir apt-get install -y $pkgs
    fi
}

chroot_apt_remove() {
    local os_dir=$1
    shift

    # minimal   grub-pc  grub-efi-amd64
    # 
    chroot_apt_update $os_dir

    #  apt remove --purge -y xxx yyy
    # 
    local pkgs=
    for pkg in "$@"; do
        # apt list  WARNING: apt does not have a stable CLI interface. Use with caution in scripts.
        #  apt-get list
        if chroot $os_dir apt list --installed "$pkg" | grep -q installed; then
            pkgs="$pkgs $pkg"
        fi
    done

    #  resolvconf  noninteractive
    DEBIAN_FRONTEND=noninteractive chroot $os_dir apt-get remove --purge --allow-remove-essential -y $pkgs
}

chroot_apt_autoremove() {
    local os_dir=$1

    change_confs() {
        action=$1

        file=$os_dir/etc/apt/apt.conf.d/01autoremove
        case "$action" in
        change)
            if [ -f $file ]; then
                sed -i.orig 's/VersionedKernelPackages/x/; s/NeverAutoRemove/x/' $file
            fi
            ;;
        restore)
            if [ -f $file.orig ]; then
                mv $file.orig $file
            fi
            ;;
        esac
    }

    change_confs change
    DEBIAN_FRONTEND=noninteractive chroot $os_dir apt-get autoremove --purge -y
    change_confs restore
}

del_default_user() {
    local os_dir=$1

    local user
    while read -r user; do
        if grep ^$user':\$' "$os_dir/etc/shadow"; then
            echo "Deleting user $user"
            chroot "$os_dir" userdel -rf "$user"
        fi
    done < <(grep -v nologin$ "$os_dir/etc/passwd" | cut -d: -f1 | grep -v root)
}

is_el7_family() {
    is_have_cmd_on_disk "$1" yum &&
        ! is_have_cmd_on_disk "$1" dnf
}

del_exist_sysconfig_NetworkManager_config() {
    local os_dir=$1

    #  dhcp 
    rm -rf $os_dir/etc/NetworkManager/system-connections/*.nmconnection
    rm -rf $os_dir/etc/sysconfig/network-scripts/ifcfg-*

    # 1.  cloud-init  IPV*_FAILURE_FATAL / may-fail=false
    #     dhcpv6  IP  fatal ipv4 
    # 2.  dhcpv6 ifcfg  IPV6_AUTOCONF=no 
    # 3.  dhcpv6 NM method=dhcp 
    if false; then
        ci_file=$os_dir/etc/cloud/cloud.cfg.d/99_fallback.cfg

        insert_into_file $ci_file after '^runcmd:' <<EOF
  - sed -i '/^IPV[46]_FAILURE_FATAL=/d' /etc/sysconfig/network-scripts/ifcfg-* || true
  - sed -i '/^may-fail=/d' /etc/NetworkManager/system-connections/*.nmconnection || true
  - for f in /etc/sysconfig/network-scripts/ifcfg-*; do grep -q '^DHCPV6C=yes' "\$f" && sed -i '/^IPV6_AUTOCONF=no/d' "\$f"; done
  - sed -i 's/^method=dhcp/method=auto/' /etc/NetworkManager/system-connections/*.nmconnection || true
  - systemctl is-enabled NetworkManager && systemctl restart NetworkManager || true
EOF
    fi
}

install_fnos() {
    info "Install fnos/fygoos"
    local os_dir=/os

    # 
    # /etc/init.d/run_install.sh > trim-install > trim-grub

    #  /os
    mkdir -p /os
    mount "/dev/$(xda 2)" /os

    #  iso
    mkdir -p /os/installer /iso
    download "$iso" /os/installer/fnos.iso
    mount -o ro /os/installer/fnos.iso /iso

    #  initrd
    apk add cpio
    initrd_dir=/os/installer/initrd_dir
    mkdir -p $initrd_dir
    (
        cd $initrd_dir
        suffix=$(
            case $(uname -m) in
            x86_64) echo amd ;;
            aarch64) echo a64 ;;
            *) ;;
            esac
        )
        zcat /iso/install.$suffix/initrd.gz | cpio -idm
    )
    apk del cpio

    # 
    fstab_line_os=$(strings $initrd_dir/trim-install | grep -m1 '^UUID=%s / ')
    fstab_line_efi=$(strings $initrd_dir/trim-install | grep -m1 '^UUID=%s /boot/efi ')
    fstab_line_swapfile=$(strings $initrd_dir/trim-install | grep -m1 '^/swapfile none swap ')

    #  initrd
    rm -rf $initrd_dir

    #  trimfs.tgz  ISO 
    echo "moving trimfs.tgz..."
    cp /iso/trimfs.tgz /os/installer
    umount /iso
    rm /os/installer/fnos.iso

    #  /os/boot/efi
    if is_efi; then
        mkdir -p /os/boot/efi
        mount -o "$(echo "$fstab_line_efi" | awk '{print $4}')" "/dev/$(xda 1)" /os/boot/efi
    fi

    # 
    info "Extract fnos/fygoos"
    apk add tar gzip pv
    pv -f /os/installer/trimfs.tgz | tar zxp --numeric-owner --xattrs-include='*.*' -C /os
    apk del tar gzip pv

    #  installer (trimfs.tgz)
    rm -rf /os/installer

    # 
    if $NEED_SHRINK_FNOS_OS_PART; then
        info "Shrink fnos/fygoos os partition"

        # 
        if is_efi; then
            umount /os/boot/efi
        fi
        umount /os

        # 101M  efi + bios_grub  bios  100M 
        # 99M 
        #  200M
        apk add e2fsprogs-extra parted
        e2fsck -p -f "/dev/$(xda 2)"
        resize2fs "/dev/$(xda 2)" "$((FNOS_OS_PART_END_M - 200))M"
        update_part
        printf "yes" | parted /dev/$xda resizepart 2 "$((FNOS_OS_PART_END_M))MiB" ---pretend-input-tty
        update_part
        resize2fs "/dev/$(xda 2)"
        update_part
        apk del e2fsprogs-extra parted

        # 
        mount "/dev/$(xda 2)" /os
        if is_efi; then
            mount -o "$(echo "$fstab_line_efi" | awk '{print $4}')" "/dev/$(xda 1)" /os/boot/efi
        fi
    fi

    #  proc sys dev
    mount_pseudo_fs /os

    # 
    if false; then
        if is_need_set_ssh_keys; then
            set_ssh_keys_and_del_password $os_dir
        else
            change_user_password $os_dir
        fi
    fi

    # ssh root 
    if false; then
        if is_need_set_ssh_keys; then
            change_ssh_conf_for_key_login $os_dir
        else
            change_ssh_conf_for_password_login $os_dir
        fi
        chroot $os_dir systemctl enable ssh
    fi

    # fstab
    {
        # /
        uuid=$(lsblk "/dev/$(xda 2)" -no UUID)
        echo "$fstab_line_os" | sed "s/%s/$uuid/"

        # swapfile
        #  swapfile  0 
        echo "$fstab_line_swapfile"

        # /boot/efi
        if is_efi; then
            uuid=$(lsblk "/dev/$(xda 1)" -no UUID)
            echo "$fstab_line_efi" | sed "s/%s/$uuid/"
        fi
    } >$os_dir/etc/fstab

    #  initrd
    #  /var/tmp  1777 
    #  /etc/fstab 
    # W: Couldn't identify type of root file system for fsck hook
    mkdir -p $os_dir/var/tmp
    chmod 1777 $os_dir/var/tmp
    chroot $os_dir update-initramfs -u

    # grub
    if is_efi; then
        chroot $os_dir grub-install --efi-directory=/boot/efi
        chroot $os_dir grub-install --efi-directory=/boot/efi --removable
    else
        chroot $os_dir grub-install /dev/$xda
    fi

    # grub 
    # strings trim-install | grep GRUB_DISTRIBUTOR
    #  sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="FNOS"/' /mnt/rootfs/etc/default/grub
    #  sed -i 's/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR="%s"/' /mnt/rootfs/etc/default/grub
    # 
    if grep -Fq fygonas.com $os_dir/etc/apt/sources.list.d/trim_repo.list; then
        name_for_grub=FygoOS
    elif grep -Fq fnnas.com $os_dir/etc/apt/sources.list.d/trim_repo.list; then
        name_for_grub=FNOS
    else
        error_and_exit 'Can not detect FNOS/FygoOS.'
    fi
    sed -i "s/^GRUB_DISTRIBUTOR=.*/GRUB_DISTRIBUTOR=\"$name_for_grub\"/" $os_dir/etc/default/grub

    # grub tty
    ttys_cmdline=$(get_ttys console=)
    echo GRUB_CMDLINE_LINUX=\"\$GRUB_CMDLINE_LINUX $ttys_cmdline\" >$os_dir/etc/default/grub.d/tty.cfg

    chroot $os_dir update-grub

    # 
    create_cloud_init_network_config /net.cfg
    create_network_manager_config /net.cfg $os_dir
    rm /net.cfg

    # 
    add_fix_eth_name_systemd_service $os_dir

    # frpc
    add_frpc_systemd_service_if_need $os_dir
}

install_qcow_by_copy() {
    info "Install qcow2 by copy"

    modify_el_ol() {
        info "Modify el ol"
        local os_dir=/os

        # resolv.conf
        cp_resolv_conf /os

        #  centos
        del_exist_sysconfig_NetworkManager_config /os

        #  ssh
        del_default_user /os

        # selinux kdump
        disable_selinux /os
        disable_kdump /os

        # el7  machine-id 
        clear_machine_id /os

        # el7 forks 
        if is_el7_family /os; then
            # centos 7 eol 
            if [ -f /os/etc/yum.repos.d/CentOS-Base.repo ]; then
                #  http  ssl 
                if is_in_china; then
                    mirror=mirror.nju.edu.cn/centos-vault
                else
                    mirror=vault.centos.org
                fi
                sed -Ei -e 's,(mirrorlist=),#\1,' \
                    -e "s,#(baseurl=http://)mirror.centos.org,\1$mirror," /os/etc/yum.repos.d/CentOS-Base.repo
            fi

            # el7 yum  ipv6 ipv6 
            if [ "$(cat /dev/netconf/*/ipv6_has_internet | sort -u)" = 0 ]; then
                echo 'ip_resolve=4' >>/os/etc/yum.conf
            fi

            # el7  NetworkManager
            # anolis 7  NetworkManager
            if ! [ -f /os/usr/lib/systemd/system/NetworkManager.service ]; then
                chroot_dnf install NetworkManager
            fi
            # 
            chroot /os systemctl disable network 2>/dev/null || true
            chroot /os systemctl enable NetworkManager
        fi

        # firmware + microcode
        if fw_pkgs=$(get_ucode_firmware_pkgs) && [ -n "$fw_pkgs" ]; then
            chroot_dnf install $fw_pkgs
        fi

        # fstab 
        # almalinux/rocky  boot 
        # oracle  swap 
        sed -i '/[[:space:]]\/boot[[:space:]]/d' /os/etc/fstab
        sed -i '/[[:space:]]swap[[:space:]]/d' /os/etc/fstab

        # os_part :
        # mapper/vg_main-lv_root
        # mapper/opencloudos-root

        # oracle/opencloudos  lvm  uuid 
        sed -i "s,/dev/$os_part,UUID=$os_part_uuid," /os/etc/fstab
        if ls /os/boot/loader/entries/*.conf 2>/dev/null; then
            # options root=/dev/mapper/opencloudos-root ro console=ttyS0,115200n8 no_timer_check net.ifnames=0 crashkernel=1800M-64G:256M,64G-128G:512M,128G-486G:768M,486G-972G:1024M,972G-:2048M rd.lvm.lv=opencloudos/root rhgb quiet
            sed -i "s,/dev/$os_part,UUID=$os_part_uuid," /os/boot/loader/entries/*.conf
        fi

        # oracle/opencloudos  lvm cmdline
        chroot /os grubby --update-kernel ALL --remove-args "resume rd.lvm.lv"
        # el7  grubby  /etc/default/grub
        sed -i 's/rd.lvm.lv=[^ "]*//g' /os/etc/default/grub

        # fstab  efi 
        if is_efi; then
            # centos/oracle efi
            if ! grep /boot/efi /os/etc/fstab; then
                efi_part_uuid=$(lsblk "/dev/$(xda 1)" -no UUID)
                echo "UUID=$efi_part_uuid /boot/efi vfat $efi_mount_opts 0 0" >>/os/etc/fstab
            fi
        else
            #  efi 
            sed -i '/[[:space:]]\/boot\/efi[[:space:]]/d' /os/etc/fstab
        fi

        remove_grub_conflict_files() {
            # bios  efi 

            # biosefi
            # centos  oracle x86_64  bios /boot/grub2/grubenv 
            # grub-efigrubenv efigrubenv
            # grub-efigrubenvgrubenv grubenv.rpmnew
            # grubenvefigrub2-setdefault

            # efibios
            # efiel8 grub2-install 
            rm -rf /os/boot/grub2/grubenv /os/boot/grub2/grub.cfg
        }

        # openeuler arm  grub.cfg  /os/grub.cfg grub 
        # centos7  grub1 
        rm -rf /os/grub.cfg /os/boot/grub/grub.conf /os/boot/grub/menu.lst

        # 
        if is_efi; then
            # centos  oracle x86_64 efiefi
            # openeuler  grub2-efi-ia32 grub2-efi  grub2-efi-ia32 grub2-efi-x64

            # qcow2  grub2-efi-x64  efi  efi 
            #  /boot/efi efi  efi 
            #  qcow2  efi 

            # rhel  yum install 
            #  yum install
            need_install=false
            need_remove_grub_conflict_files=false

            [ "$(uname -m)" = x86_64 ] && arch=x64 || arch=aa64
            if ! chroot $os_dir rpm -qi grub2-efi-$arch; then
                need_install=true
                need_remove_grub_conflict_files=true
            elif ! chroot $os_dir rpm -qi shim-$arch || ! chroot $os_dir rpm -qi efibootmgr; then
                need_install=true
            fi

            if $need_install; then
                if $need_remove_grub_conflict_files; then
                    remove_grub_conflict_files
                fi
                chroot_dnf install efibootmgr grub2-efi-$arch shim-$arch
            fi
            # openeuler arm 25.09  grubaa64.efi  mbr $root  hd0,msdos1
            #  $root  hd0,gpt1  grubaa64.efi
            if $need_reinstall_grub_efi; then
                chroot_dnf reinstall grub2-efi-$arch
            fi
        else
            # bios
            remove_grub_conflict_files
            chroot /os/ grub2-install /dev/$xda
        fi

        # blscfg 
        # rocky/almalinuxboot
        # boot
        if ls /os/boot/loader/entries/*.conf 2>/dev/null &&
            ! grep -q 'initrd /boot/' /os/boot/loader/entries/*.conf; then

            sed -i -E 's,((linux|initrd) /),\1boot/,g' /os/boot/loader/entries/*.conf
        fi

        # grub-efi-x64  /etc/grub2-efi.cfg
        #  /boot/efi/EFI/xxx/grub.cfg  /boot/grub2/grub.cfg
        #  grub2-mkconfig 
        # grubby  /etc/grub2-efi.cfg  grub.cfg 
        # openeuler 24.03 x64 aa64 
        if is_efi; then
            grub_o_cfg=$(chroot /os readlink -f /etc/grub2-efi.cfg)
        else
            grub_o_cfg=/boot/grub2/grub.cfg
        fi

        # efi  grub.cfg
        # https://github.com/rhinstaller/anaconda/blob/346b932a26a19b339e9073c049b08bdef7f166c3/pyanaconda/modules/storage/bootloader/efi.py#L198
        # https://github.com/rhinstaller/anaconda/commit/15c3b2044367d375db6739e8b8f419ef3e17cae7
        if is_efi && ! echo "$grub_o_cfg" | grep -q '/boot/efi/EFI'; then
            # oracle linux  redhat
            # shellcheck disable=SC2010
            distro_efi=$(cd /os/boot/efi/EFI/ && ls -d -- * | grep -Eiv BOOT)
            cat <<EOF >/os/boot/efi/EFI/$distro_efi/grub.cfg
search --no-floppy --fs-uuid --set=dev $os_part_uuid
set prefix=(\$dev)/boot/grub2
export \$prefix
configfile \$prefix/grub.cfg
EOF
        fi

        #  grub.cfg
        if ls /os/boot/loader/entries/*.conf >/dev/null 2>&1 &&
            chroot /os/ grub2-mkconfig --help | grep -q update-bls-cmdline; then
            chroot /os/ grub2-mkconfig -o "$grub_o_cfg" --update-bls-cmdline
        else
            chroot /os/ grub2-mkconfig -o "$grub_o_cfg"
        fi

        # 
        # el7/8 sysconfig
        # el9 network-manager
        if [ -f $os_dir/etc/sysconfig/network-scripts/ifup-eth ]; then
            # sysconfig
            info 'sysconfig'

            # anolis/openeuler/opencloudos  cloud-init
            # opencloudos  chroot $os_dir command -v xxx
            # chroot: failed to run command ‘command’: No such file or directory
            #  cloud-init 
            if ! is_have_cmd_on_disk $os_dir cloud-init; then
                chroot_dnf install cloud-init
            fi

            # cloud-init 
            # /usr/lib/python2.7/site-packages/cloudinit/net/
            # /usr/lib/python3/dist-packages/cloudinit/net/
            # /usr/lib/python3.9/site-packages/cloudinit/net/

            # el7  static6 static
            recognize_static6=true
            if ls $os_dir/usr/lib/python*/*-packages/cloudinit/net/sysconfig.py 2>/dev/null &&
                ! grep -q static6 $os_dir/usr/lib/python*/*-packages/cloudinit/net/sysconfig.py; then
                recognize_static6=false
            fi

            # cloud-init 20.1 
            # https://cloudinit.readthedocs.io/en/20.4/topics/network-config-format-v1.html#subnet-ip
            # https://cloudinit.readthedocs.io/en/21.1/topics/network-config-format-v1.html#subnet-ip
            # ipv6_dhcpv6-stateful: Configure this interface with dhcp6
            # ipv6_dhcpv6-stateless: Configure this interface with SLAAC and DHCP
            # ipv6_slaac: Configure address with SLAAC

            # el7  cloud-init 
            # centos 7         19.4-7.0.5.el7_9.6  backport  ipv6_xxx
            # openeuler 20.03  19.4-15.oe2003sp4   backport  ipv6_xxx
            # anolis 7         19.1.17-1.0.1.an7    centos7 , backport ipv6_xxx

            #  ifcfg-eth*  IPV6_AUTOCONF
            #  anolis7 cloud-init dhcp6  IPV6_AUTOCONF
            # https://www.redhat.com/zh/blog/configuring-ipv6-rhel-7-8
            recognize_ipv6_types=true
            if ls -d $os_dir/usr/lib/python*/*-packages/cloudinit/net/ 2>/dev/null &&
                ! grep -qr ipv6_slaac $os_dir/usr/lib/python*/*-packages/cloudinit/net/; then
                recognize_ipv6_types=false
            fi

            #  cloud-init 
            create_cloud_init_network_config $os_dir/net.cfg "$recognize_static6" "$recognize_ipv6_types"

            # 
            chroot $os_dir cloud-init devel net-convert \
                -p /net.cfg -k yaml -d out -D rhel -O sysconfig
            cp $os_dir/out/etc/sysconfig/network-scripts/ifcfg-eth* $os_dir/etc/sysconfig/network-scripts/

            # 
            rm -rf $os_dir/net.cfg $os_dir/out

            #  # Created by cloud-init on instance boot automatically, do not edit.
            # 
            sed -i -e '/^IPV[46]_FAILURE_FATAL=/d' -e '/^#/d' $os_dir/etc/sysconfig/network-scripts/ifcfg-*
            for file in "$os_dir/etc/sysconfig/network-scripts/ifcfg-"*; do
                if grep -q '^DHCPV6C=yes' "$file"; then
                    sed -i '/^IPV6_AUTOCONF=no/d' "$file"
                fi
                cat -n "$file"
            done
        else
            # Network Manager
            info 'Network Manager'

            create_cloud_init_network_config /net.cfg
            create_network_manager_config /net.cfg "$os_dir"

            # 
            rm /net.cfg
        fi

        # dns
        rm_resolv_conf /os
    }

    modify_ubuntu() {
        local os_dir=/os
        info "Modify Ubuntu"

        cp_resolv_conf $os_dir

        #  os prober os prober 
        cp $os_dir/etc/default/grub $os_dir/etc/default/grub.orig
        echo 'GRUB_DISABLE_OS_PROBER=true' >>$os_dir/etc/default/grub

        # 
        if is_in_china; then
            # 22.04  /etc/apt/sources.list
            # 24.04  /etc/apt/sources.list.d/ubuntu.sources
            for file in $os_dir/etc/apt/sources.list $os_dir/etc/apt/sources.list.d/ubuntu.sources; do
                if [ -f $file ]; then
                    # cn.archive.ubuntu.com 
                    # https://www.itdog.cn/ping/cn.archive.ubuntu.com
                    sed -i 's/archive.ubuntu.com/mirror.nju.edu.cn/' $file # x64
                    sed -i 's/ports.ubuntu.com/mirror.nju.edu.cn/' $file   # arm
                fi
            done
        fi

        #  do-release-upgrade  dpkg-reconfigure grub-xx  efi/biosgrub 
        # shellcheck disable=SC2046
        chroot_apt_remove $os_dir $(is_efi && echo 'grub-pc' || echo 'grub-efi*' 'shim*')
        chroot_apt_autoremove $os_dir

        #  mbr
        if ! is_efi; then
            if false; then
                # debconf-show grub-pc
                #  debian netboot  grub-pc/install_devices
                echo grub-pc grub-pc/install_devices multiselect /dev/$xda | chroot $os_dir debconf-set-selections # 22.04
                echo grub-pc grub-pc/cloud_style_installation boolean true | chroot $os_dir debconf-set-selections # 24.04
                chroot $os_dir dpkg-reconfigure -f noninteractive grub-pc
            else
                chroot $os_dir grub-install /dev/$xda
            fi
        fi

        # 
        #              generic
        # minimal 20.04/22.04 kvm      #  vnc 
        # minimal 24.04       virtual

        # debian cloud  ahciubuntu virtual 

        # 
        #  linux-base
        #  0
        pkgs=$(chroot $os_dir apt-mark showmanual \
            linux-generic linux-virtual linux-kvm \
            linux-image* linux-headers*)
        chroot $os_dir apt-mark auto $pkgs

        # 
        flavor=$(get_ubuntu_kernel_flavor)
        echo "Use kernel flavor: $flavor"

        # 
        #  auto 
        #  apt install PKG  manual
        #  apt install PKG  manual

        #  apt-mark manual
        chroot_apt_install $os_dir "linux-image-$flavor"

        #  autoremove 
        chroot_apt_autoremove $os_dir

        # +
        if fw_pkgs=$(get_ucode_firmware_pkgs) && [ -n "$fw_pkgs" ]; then
            chroot_apt_install $os_dir $fw_pkgs
        fi

        # 
        # 18.04+ netplan
        #  cloud-init minimal  netplan.io  autoremove
        chroot $os_dir apt-mark manual netplan.io

        #  cloud-init 
        create_cloud_init_network_config $os_dir/net.cfg

        # ubuntu 18.04 cloud-init  23.1.2 onlink

        #  /  50-cloud-init.yaml
        # 
        if false; then
            chroot $os_dir cloud-init devel net-convert \
                -p /net.cfg -k yaml -d /out -D ubuntu -O netplan
            sed -Ei "/^[[:space:]]+set-name:/d" $os_dir/out/etc/netplan/50-cloud-init.yaml
            cp $os_dir/out/etc/netplan/50-cloud-init.yaml $os_dir/etc/netplan/

            # 
            rm -rf $os_dir/net.cfg $os_dir/out
        else
            chroot $os_dir cloud-init devel net-convert \
                -p /net.cfg -k yaml -d / -D ubuntu -O netplan
            sed -Ei "/^[[:space:]]+set-name:/d" $os_dir/etc/netplan/50-cloud-init.yaml

            # 
            rm -rf $os_dir/net.cfg
        fi

        #  60-cloudimg-settings.conf  PasswordAuthentication
        #  sshd  sshd 
        #  60-cloudimg-settings.conf  change_ssh_conf_if_different 
        if false; then
            file=$os_dir/etc/ssh/sshd_config.d/60-cloudimg-settings.conf
            if [ -f $file ]; then
                sed -i '/^PasswordAuthentication/d' $file
                if [ -z "$(cat $file)" ]; then
                    rm -f $file
                fi
            fi
        fi

        #  efi  grub.cfg  fsuuid
        #  24.04 fsuuid  boot 
        efi_grub_cfg=$os_dir/boot/efi/EFI/ubuntu/grub.cfg
        if is_efi; then
            os_uuid=$(lsblk -rno UUID "/dev/$(xda 2)")
            sed -Ei "s|[0-9a-f-]{36}|$os_uuid|i" $efi_grub_cfg

            # 24.04  boot  /boot 
            if grep "'/grub'" $efi_grub_cfg; then
                sed -i "s|'/grub'|'/boot/grub'|" $efi_grub_cfg
            fi
        fi

        #  40-force-partuuid.cfg
        force_partuuid_cfg=$os_dir/etc/default/grub.d/40-force-partuuid.cfg
        if [ -e $force_partuuid_cfg ]; then
            if is_virt; then
                #  partuuid
                os_part_uuid=$(lsblk -rno PARTUUID "/dev/$(xda 2)")
                sed -i "s/^GRUB_FORCE_PARTUUID=.*/GRUB_FORCE_PARTUUID=$os_part_uuid/" $force_partuuid_cfg
            else
                #  initrdless boot
                sed -i "/^GRUB_FORCE_PARTUUID=/d" $force_partuuid_cfg
            fi
        fi

        #  grub.cfg
        # 1  boot 
        # 2  /etc/default/grub.d/40-force-partuuid.cfg
        chroot $os_dir update-grub

        #  grub os prober
        mv $os_dir/etc/default/grub.orig $os_dir/etc/default/grub

        # fstab
        # 24.04 boot
        sed -i '/[[:space:]]\/boot[[:space:]]/d' $os_dir/etc/fstab
        if ! is_efi; then
            # bios  efi 
            sed -i '/[[:space:]]\/boot\/efi[[:space:]]/d' $os_dir/etc/fstab
        fi

        restore_resolv_conf $os_dir
    }

    efi_mount_opts=$(
        case "$distro" in
        ubuntu) echo "umask=0077" ;;
        *) echo "defaults,uid=0,gid=0,umask=077,shortname=winnt" ;;
        esac
    )

    # yum/apt 
    need_ram=$(
        case "$distro" in
        ubuntu) echo 1024 ;;
        *) echo 2048 ;;
        esac
    )

    connect_qcow

    # 
    # centos/rocky/almalinux/rhel: xfs
    # oracle x86_64:          lvm + xfs
    # oracle aarch64 cloud:   xfs
    # alibaba cloud linux 3:  ext4

    is_lvm_image=false
    if lsblk -f /dev/nbd0p* | grep LVM2_member; then
        is_lvm_image=true
        apk add lvm2
        lvscan
        vg=$(pvs | grep /dev/nbd0p | awk '{print $2}')
        lvchange -ay "$vg"
    fi

    mount_nouuid() {
        part_fstype=
        for arg in "$@"; do
            case "$arg" in
            /dev/*)
                part_fstype=$(lsblk -no FSTYPE "$arg")
                break
                ;;
            esac
        done

        case "$part_fstype" in
        xfs) mount -o nouuid "$@" ;;
        *) mount "$@" ;;
        esac
    }

    # ?
    # almalinux9 boot  uuid
    # openeuler boot  vfat 
    # openeuler arm 25.09  mbr , efi boot vfat 

    info "qcow2 Partitions check"

    # 
    partition_table_format=$(get_partition_table_format /dev/nbd0)
    need_reinstall_grub_efi=false
    if is_efi && [ "$partition_table_format" = "msdos" ]; then
        need_reinstall_grub_efi=true
    fi

    # 
    os_part='' boot_part='' efi_part=''
    mkdir -p /nbd-test
    for part in $(lsblk /dev/nbd0p* --sort SIZE -no NAME,FSTYPE |
        grep -E ' (ext4|xfs|fat|vfat)$' | awk '{print $1}' | tac); do
        mapper_part=$part
        if $is_lvm_image && [ -e /dev/mapper/$part ]; then
            mapper_part=mapper/$part
        fi

        if mount_nouuid -o ro /dev/$mapper_part /nbd-test; then
            if { ls /nbd-test/etc/os-release || ls /nbd-test/*/etc/os-release; } 2>/dev/null; then
                os_part=$mapper_part
            fi
            # shellcheck disable=SC2010
            #  boot vmlinuz 
            #  boot vmlinuz  /boot 
            if ls /nbd-test/ /nbd-test/boot/ 2>/dev/null | grep -Ei '^(vmlinuz|initrd|initramfs)'; then
                boot_part=$mapper_part
            fi
            # mbr + efi   esp guid
            #  efi  efi 
            # efi  efi 
            if find /nbd-test/ -type f -ipath '/nbd-test/EFI/*.efi' 2>/dev/null | grep .; then
                efi_part=$mapper_part
            fi
            umount /nbd-test
        fi
    done

    info "qcow2 Partitions"
    lsblk -f /dev/nbd0 -o +PARTTYPE
    #  OS/EFI/Boot 
    echo "---"
    echo "Table:     $partition_table_format"
    echo "Part OS:   $os_part"
    echo "Part EFI:  $efi_part"
    echo "Part Boot: $boot_part"
    echo "---"

    # 
    # /          cmdline:root  fstab:efi
    # rocky             LABEL=rocky   LABEL=EFI
    # ubuntu            PARTUUID      LABEL=UEFI
    # el/ol         UUID           UUID

    IFS=, read -r os_part_uuid os_part_label os_part_fstype \
        < <(lsblk /dev/$os_part -rno UUID,LABEL,FSTYPE | tr ' ' ,)

    if [ -n "$efi_part" ]; then
        IFS=, read -r efi_part_uuid efi_part_label \
            < <(lsblk /dev/$efi_part -rno UUID,LABEL | tr ' ' ,)
    fi

    mkdir -p /nbd /nbd-boot /nbd-efi

    # 
    # centos8 alpinexfsgrub2-mkconfiggrub2xfs
    mount_nouuid /dev/$os_part /nbd/
    mount_pseudo_fs /nbd/
    case "$os_part_fstype" in
    ext4) chroot /nbd mkfs.ext4 -F -L "$os_part_label" -U "$os_part_uuid" "/dev/$(xda 2)" ;;
    xfs) chroot /nbd mkfs.xfs -f -L "$os_part_label" -m uuid=$os_part_uuid "/dev/$(xda 2)" ;;
    esac
    umount -R /nbd/

    # TODO: ubuntu  mkfs.fat/vfat/dosfstools? initrd fs

    #  /os
    mkdir -p /os
    mount -o noatime "/dev/$(xda 2)" /os/

    #  efi  /os/boot/efi
    #  efi  /os/boot/efi efi 
    if is_efi || [ -n "$efi_part" ]; then
        mkdir -p /os/boot/efi/

        #  /os/boot/efi
        #  /os/boot/efi  boot  efi openeuler 24.03 arm
        #  boot  efi 
        if is_efi; then
            mount -o $efi_mount_opts "/dev/$(xda 1)" /os/boot/efi/
        fi
    fi

    # 
    echo Copying os partition...
    mount_nouuid -o ro /dev/$os_part /nbd/
    cp -a /nbd/* /os/
    umount /nbd/

    # boot
    if [ -n "$boot_part" ] && ! [ "$boot_part" = "$os_part" ]; then
        echo Copying boot partition...
        mount_nouuid -o ro /dev/$boot_part /nbd-boot/
        cp -a /nbd-boot/* /os/boot/
        umount /nbd-boot/
    fi

    # efi
    #  efi  boot  boot  efi 
    if [ -n "$efi_part" ] && ! [ "$efi_part" = "$os_part" ] && ! [ "$efi_part" = "$boot_part" ]; then
        echo Copying efi partition...
        mount -o ro /dev/$efi_part /nbd-efi/
        cp -a /nbd-efi/* /os/boot/efi/
        umount /nbd-efi/
    fi

    #  qcow  qemu-img
    info "Disconnecting qcow2"
    if is_have_cmd vgchange; then
        vgchange -an
        apk del lvm2
    fi
    disconnect_qcow
    apk del qemu-img

    # 
    info "Unmounting disk"
    if is_efi; then
        umount /os/boot/efi/
    fi
    umount /os/
    umount /installer/

    # efiefi+bootuuid
    # uuidfat
    # efinbduuid
    # uuid efi 
    if is_efi && [ -n "$efi_part_uuid" ] && ! [ "$efi_part" = "$os_part" ]; then
        info "Copy efi partition uuid"
        apk add mtools
        mlabel -N "$(echo $efi_part_uuid | sed 's/-//')" -i "/dev/$(xda 1)" ::$efi_part_label
        apk del mtools
        update_part
    fi

    #  installer 
    info "Delete installer partition"
    apk add parted
    parted /dev/$xda -s -- rm 3
    update_part
    resize_after_install_cloud_image

    #  /os /boot/efi
    info "Re-mount disk"
    mount -o noatime "/dev/$(xda 2)" /os/
    if is_efi; then
        mount -o $efi_mount_opts "/dev/$(xda 1)" /os/boot/efi/
    fi

    #  swap
    create_swap_if_ram_less_than $need_ram /os/swapfile

    # 
    mount_pseudo_fs /os/

    case "$distro" in
    ubuntu) modify_ubuntu ;;
    *) modify_el_ol ;;
    esac

    # 
    basic_init /os

    #  cloud-init
    #  netplan/sysconfig  cloud-init
    remove_or_disable_cloud_init /os

    #  swapfile
    swapoff -a
    rm -f /os/swapfile
}

get_partition_table_format() {
    apk add parted
    parted "$1" -s print | grep 'Partition Table:' | awk '{print $NF}'
}

dd_qcow() {
    info "DD qcow2"

    if true; then
        connect_qcow

        partition_table_format=$(get_partition_table_format /dev/nbd0)
        orig_nbd_virtual_size=$(get_disk_size /dev/nbd0)

        #  btrfs
        # awk0 grep . 
        if part_num=$(parted /dev/nbd0 -s print | awk NF | tail -1 | grep btrfs | awk '{print $1}' | grep .); then
            apk add btrfs-progs
            mkdir -p /mnt/btrfs
            mount /dev/nbd0p$part_num /mnt/btrfs

            # 
            btrfs device usage /mnt/btrfs
            btrfs balance start -dusage=0 /mnt/btrfs
            btrfs device usage /mnt/btrfs

            # 
            free_bytes=$(btrfs device usage /mnt/btrfs -b | grep Unallocated: | awk '{print $2}')
            reserve_bytes=$((100 * 1024 * 1024)) #  100M 
            skrink_bytes=$((free_bytes - reserve_bytes))

            if [ $skrink_bytes -gt 0 ]; then
                # 
                btrfs filesystem resize -$skrink_bytes /mnt/btrfs
                # 
                part_start=$(parted /dev/nbd0 -s 'unit b print' | awk "\$1==$part_num {print \$2}" | sed 's/B//')
                part_size=$(btrfs filesystem usage /mnt/btrfs -b | grep 'Device size:' | awk '{print $3}')
                part_end=$((part_start + part_size - 1))
                umount /mnt/btrfs
                printf "yes" | parted /dev/nbd0 resizepart $part_num ${part_end}B ---pretend-input-tty

                #  qcow2
                disconnect_qcow
                qemu-img resize --shrink $qcow_file $((part_end + 1))

                # 
                connect_qcow
            else
                umount /mnt/btrfs
            fi
        fi

        # 
        lsblk -o NAME,SIZE,FSTYPE,LABEL /dev/nbd0

        # 1M dd
        dd if=/dev/nbd0 of=/first-1M bs=1M count=1

        # 1M dd
        # shellcheck disable=SC2194
        case 3 in
        1)
            # BusyBox dd
            dd if=/dev/nbd0 of=/dev/$xda bs=1M skip=1 seek=1
            ;;
        2)
            #  dd status=progress
            apk add coreutils
            dd if=/dev/nbd0 of=/dev/$xda bs=1M skip=1 seek=1 status=progress
            ;;
        3)
            #  pv
            apk add pv
            echo "Start DD Cloud Image..."
            pv -f /dev/nbd0 | dd of=/dev/$xda bs=1M skip=1 seek=1 iflag=fullblock
            ;;
        esac

        disconnect_qcow
    else
        # 1M dd1M dd
        qemu-img dd if=$qcow_file of=/first-1M bs=1M count=1
        qemu-img dd if=$qcow_file of=/dev/disk/by-label/os bs=1M skip=1
    fi

    #  dd  qcow qemu-img
    apk del qemu-img

    # 1M dd 
    umount /installer/
    dd if=/first-1M of=/dev/$xda
    rm -f /first-1M

    # gpt 
    #  qcow2   
    #  
    # partprobe 
    # Error: Invalid argument during seek for read on /dev/vda
    # parted 
    # 

    #  qcow2  5g
    # openSUSE-Leap-15.5-Minimal-VM.x86_64-kvm-and-xen.qcow2  25g
    #  btrfs  dd  10g 
    #  25g
    #  10g 
    #  partprobe parted 

    #  sgdisk 
    if [ "$partition_table_format" = gpt ] &&
        [ "$orig_nbd_virtual_size" -gt "$(get_disk_size /dev/$xda)" ]; then
        fix_gpt_backup_partition_table_by_sgdisk
    fi
    update_part
}

fix_gpt_backup_partition_table_by_sgdisk() {
    #  sgdisk 
    #  DD
    #  openSUSE-Leap-15.5-Minimal-VM.x86_64-kvm-and-xen.qcow2

    # parted 
    # parted /dev/$xda -f -s print

    # fdisk/sfdisk 
    # echo write | sfdisk /dev/$xda
    # GPT PMBR size mismatch (50331647 != 20971519) will be corrected by write.
    # The primary GPT table is corrupt, but the backup appears OK, so that will be used.

    #  parted 

    apk add sgdisk

    #  GUID
    #  sgdisk -v /dev/vda  guid 
    # localhost:~# sgdisk -v /dev/$xda
    # Problem: main header's disk GUID (A24485F3-2C02-43BD-BF4E-F52E42B00DEA) doesn't
    # match the backup GPT header's disk GUID (ADAF57BC-B4F5-4E04-BCBA-BDDCD796C388)
    # You should use the 'b' or 'd' option on the recovery & transformation menu to
    # select one or the other header.
    if false; then
        sgdisk --backup /gpt-partition-table /dev/$xda
        sgdisk --load-backup /gpt-partition-table /dev/$xda
    else
        sgdisk --move-second-header /dev/$xda
    fi

    #  guid
    if new_guid=$(sgdisk -v /dev/$xda | grep GUID | head -1 | grep -Eo '[0-9A-F-]{36}'); then
        sgdisk --disk-guid $new_guid /dev/$xda
    fi

    update_part

    apk del sgdisk
}

#  DD  gpt 
fix_gpt_backup_partition_table_by_parted() {
    apk add parted
    parted /dev/$xda -f -s print
    update_part
}

resize_after_install_cloud_image() {
    # 
    # 1  vultr 512m debian 11 generic/genericcloud  kernel panic
    # 2  gentoo  websync 
    info "Resize after dd"
    lsblk -f /dev/$xda

    # 
    fix_gpt_backup_partition_table_by_parted

    disk_size=$(get_disk_size /dev/$xda)
    disk_end=$((disk_size - 1))

    #  _ 6 last_part_fs
    IFS=: read -r last_part_num _ last_part_end _ last_part_fs _ \
        < <(parted -msf /dev/$xda 'unit b print' | tail -1)
    last_part_end=$(echo $last_part_end | sed 's/B//')

    if [ $((disk_end - last_part_end)) -ge 0 ]; then
        printf "yes" | parted /dev/$xda resizepart $last_part_num 100% ---pretend-input-tty
        update_part

        mkdir -p /os

        # lvm ?
        #  cloud-utils-growpart
        case "$last_part_fs" in
        ext4)
            # debian ci
            apk add e2fsprogs-extra
            e2fsck -p -f "/dev/$(xda $last_part_num)"
            resize2fs "/dev/$(xda $last_part_num)"
            apk del e2fsprogs-extra
            ;;
        xfs)
            # opensuse ci
            apk add xfsprogs-extra
            mount "/dev/$(xda $last_part_num)" /os
            xfs_growfs "/dev/$(xda $last_part_num)"
            umount /os
            apk del xfsprogs-extra
            ;;
        btrfs)
            # fedora ci
            apk add btrfs-progs
            mount "/dev/$(xda $last_part_num)" /os
            btrfs filesystem resize max /os
            umount /os
            apk del btrfs-progs
            ;;
        ntfs)
            # windows dd
            apk add ntfs-3g-progs
            echo y | ntfsresize "/dev/$(xda $last_part_num)"
            ntfsfix -d "/dev/$(xda $last_part_num)"
            apk del ntfs-3g-progs
            ;;
        esac
        update_part
        parted /dev/$xda -s print
    fi
}

mount_part_basic_layout() {
    local os_dir=$1
    local efi_dir=$2

    if is_efi || is_xda_gt_2t; then
        os_part_num=2
    else
        os_part_num=1
    fi

    # 
    mkdir -p $os_dir
    mount -t ext4 "/dev/$(xda $os_part_num)" $os_dir

    #  efi 
    if is_efi; then
        mkdir -p $efi_dir
        mount -t vfat -o umask=077 "/dev/$(xda 1)" $efi_dir
    fi
}

mount_part_for_iso_installer() {
    info "Mount part for iso installer"

    if [ "$distro" = windows ]; then
        mount_args="-t ntfs3 -o nocase"
    else
        mount_args=
    fi

    # 
    mkdir -p /os
    mount $mount_args /dev/disk/by-label/os /os

    # 
    if is_efi; then
        mkdir -p /os/boot/efi
        mount /dev/disk/by-label/efi /os/boot/efi
    fi
    mkdir -p /os/installer
    mount $mount_args /dev/disk/by-label/installer /os/installer
}

get_dns_list_for_win() {
    if dns_list=$(get_current_dns $1); then
        i=0
        for dns in $dns_list; do
            i=$((i + 1))
            echo "set ipv${1}_dns$i=$dns"
        done
    fi
}

create_win_set_netconf_script() {
    target=$1
    info "Create win netconf script"

    if is_staticv4 || is_staticv6 || is_need_manual_set_dnsv6; then
        get_netconf_to mac_addr
        echo "set mac_addr=$mac_addr" >$target

        #  ipv4 
        if is_staticv4; then
            get_netconf_to ipv4_addr
            get_netconf_to ipv4_gateway
            cat <<EOF >>$target
set ipv4_addr=$ipv4_addr
set ipv4_gateway=$ipv4_gateway
$(get_dns_list_for_win 4)
EOF
        fi

        #  ipv6 
        if is_staticv6; then
            get_netconf_to ipv6_addr
            get_netconf_to ipv6_gateway
            cat <<EOF >>$target
set ipv6_addr=$ipv6_addr
set ipv6_gateway=$ipv6_gateway
EOF
        fi

        #  ipv6  dns 
        if is_need_manual_set_dnsv6; then
            cat <<EOF >>$target
$(get_dns_list_for_win 6)
EOF
        fi

        cat -n $target
    fi

    # ipv6id
    # 
    wget $confhome/windows-set-netconf.bat -O- >>$target
    unix2dos $target
}

create_win_change_rdp_port_script() {
    target=$1
    rdp_port=$2

    info "Create win change rdp port script"

    echo "set RdpPort=$rdp_port" >$target
    wget $confhome/windows-change-rdp-port.bat -O- >>$target
    unix2dos $target
}

# virt-what 
# vultr 1G High Frequency LAX  kvm
# debian 11 virt-what 1.19  hyperv qemu
# debian 11 systemd-detect-virt  microsoft
# alpine virt-what 1.25  kvm
# 

# lscpu  alpine on lightsail  Microsoft
#  lscpu  cpuid  dmi
# virt-what  grep

get_aws_repo() {
    if is_in_china >&2; then
        echo https://s3.cn-north-1.amazonaws.com.cn/ec2-windows-drivers-downloads-cn
    else
        echo https://s3.amazonaws.com/ec2-windows-drivers-downloads
    fi
}

#  AC/SAC   LTSC 
# 
get_windows_name_by_version() {
    local nt_ver=$1
    local build_ver=$2
    local windows_type=$3

    local windows_name
    windows_name=$(
        case "$windows_type" in
        client)
            case "$nt_ver" in
            10.0)
                if [ "$build_ver" -ge 22000 ]; then
                    echo 11
                else
                    echo 10
                fi
                ;;
            6.3) echo 8.1 ;;
            6.2) echo 8 ;;
            6.1) echo 7 ;;
            6.0) echo vista ;;
            esac
            ;;

        server)
            case "$nt_ver" in
            10.0)
                if [ "$build_ver" -ge 26100 ]; then
                    echo 2025
                elif [ "$build_ver" -ge 20348 ]; then
                    echo 2022
                elif [ "$build_ver" -ge 17763 ]; then
                    echo 2019
                else
                    echo 2016
                fi
                ;;
            6.3) echo '2012 r2' ;;
            6.2) echo '2012' ;;
            6.1) echo '2008 r2' ;;
            6.0) echo '2008' ;;
            esac
            ;;
        esac
    )

    if [ -n "$windows_name" ]; then
        echo "$windows_name"
    else
        error_and_exit "Unknown Windows Version: $nt_ver $build_ver $windows_type"
    fi
}

is_nt_ver_ge() {
    local orig sorted
    orig=$(printf '%s\n' "$1" "$nt_ver")
    sorted=$(echo "$orig" | sort -V)
    [ "$orig" = "$sorted" ]
}

# reinstall.sh 
is_administrator_username() {
    username_in_lower=$(printf "%s" "$1" | to_lower)

    for builtin_username in \
        administrator \
        administrador \
        administrateur \
        administratör \
        администратор \
        järjestelmänvalvoja \
        rendszergazda; do
        if [ "$username_in_lower" = "$builtin_username" ]; then
            return 0
        fi
    done

    return 1
}

get_cloud_vendor() {
    # busybox blkid  sr0  UUID
    apk add lsblk

    # http://git.annexia.org/?p=virt-what.git;a=blob;f=virt-what.in;hb=HEAD
    # virt-what  aws google_cloud alibaba_cloud alibaba_cloud-ebm
    if is_dmi_contains "Amazon EC2" || is_virt_contains aws; then
        echo aws
    elif is_dmi_contains "Google Compute Engine" || is_dmi_contains "GoogleCloud" || is_virt_contains google_cloud; then
        echo gcp
    elif is_dmi_contains "OracleCloud"; then
        echo oracle
    elif is_dmi_contains "7783-7084-3265-9085-8269-3286-77"; then
        echo azure
    elif lsblk -o UUID,LABEL | grep -i 9796-932E | grep -iq config-2; then
        echo ibm
    elif is_dmi_contains 'Huawei Cloud'; then
        echo huawei
    elif is_dmi_contains 'Alibaba Cloud'; then
        echo aliyun
    elif is_dmi_contains 'Tencent Cloud'; then
        echo qcloud
    fi
}

get_filesize_mb() {
    du -m "$1" | awk '{print $1}'
}

mkdir_clear() {
    local dir=$1

    if [ -z "$dir" ] || [ "$dir" = / ]; then
        return
    fi

    rm -rf "$dir"
    mkdir -p "$dir"
}

#  list=$(list_add "$list" "$item_to_add")
list_add() {
    local list=$1
    local item_to_add=$2
    if [ -n "$list" ]; then
        echo "$list"
    fi
    echo "$item_to_add"
}

is_list_has() {
    local list=$1
    local item=$2
    echo "$list" | grep -qFx "$item"
}

# reinstall.sh 
get_drivers() {
    (
        cd "$(readlink -f $1)"
        while ! [ "$(pwd)" = / ]; do
            if [ -d driver ]; then
                if [ -d driver/module ]; then
                    basename "$(readlink -f driver/module)"
                else
                    basename "$(readlink -f driver)"
                fi
            fi
            cd ..
        done
    )
}

get_windows_type_from_windows_drive() {
    local os_dir=$1

    apk add hivex-perl
    system_hive=$(find_file_ignore_case $os_dir/Windows/System32/config/SYSTEM)
    product_type=$(hivexget $system_hive '\ControlSet001\Control\ProductOptions' ProductType)
    apk del hivex-perl

    # ProductType InstallationType 
    #  ProductType
    # https://learn.microsoft.com/windows-hardware/drivers/install/inf-manufacturer-section
    # NTamd64.10.0       #  ProductType
    # NTamd64.10.0.1     #  ProductType  1 

    #  ProductType
    #  win11  e1d.inf 
    # win11 enterprise       i218-V/i-219V i218-LM/i219-LM
    # win11 multi-session  i218-V/i-219V i218-LM/i219-LM

    case "$product_type" in
    WinNT) echo client ;;
    LanmanNT | ServerNT) echo server ;;
    *) error_and_exit "Unexpected Product Type: $product_type" ;;
    esac
}

get_windows_arch_from_windows_drive() {
    local os_dir=$1

    apk add hivex-perl
    hive=$(find_file_ignore_case $os_dir/Windows/System32/config/SYSTEM)
    #  CurrentControlSet
    hivexget $hive 'ControlSet001\Control\Session Manager\Environment' PROCESSOR_ARCHITECTURE
    apk del hivex-perl
}

get_intel_download_url() {
    local id=$1
    local file_regex=$2

    if is_in_china; then
        local url=https://www.intel.cn/content/www/cn/zh/download/$id.html
    else
        local url=https://www.intel.com/content/www/us/en/download/$id.html
    fi

    # 
    # intel  wget 
    wget -U curl/7.54.1 "$url" -O- | sed 's,",\n,g' |
        grep -Eio -m1 "https://.+/$file_regex" | grep .
}

apk_add_from_edge() {
    #  edge/community 
    # 
    local alpine_mirror
    alpine_mirror=$(grep '^http.*/main$' /etc/apk/repositories | sed 's,/[^/]*/main$,,' | head -1)
    apk add --repository "$alpine_mirror/edge/community" \
        --force-non-repository \
        --virtual edge \
        "$@"
}

apk_del_edge() {
    apk del edge
}

install_windows() {
    get_wim_prop() {
        wim=$1
        property=$2

        wiminfo "$wim" | grep -i "^$property:" | cut -d: -f2- | trim
    }

    get_image_prop() {
        wim=$1
        index=$2
        property=$3

        wiminfo "$wim" "$index" | grep -i "^$property:" | cut -d: -f2- | trim
    }

    info "Process windows iso"
    mkdir -p /iso /wim

    # find_file_ignore_case 
    # shellcheck disable=SC1090
    . <(wget -O- $confhome/windows-driver-utils.sh)

    apk add wimlib

    download $iso /os/windows.iso
    mount -o ro /os/windows.iso /iso

    sources_boot_wim=$(
        cd /iso
        find_file_ignore_case sources/boot.wim 2>/dev/null ||
            error_and_exit "can't find boot.wim"
    )

    #  install.wim
    # en_server_install_disc_windows_home_server_2011_x64_dvd_658487.iso  Install.wim
    # en_windows_vista_sp2_with_update_6003.23713_aio_7in1_x64_v26.01.13_by_adguard.iso  swm
    source_install_wim=$(
        cd /iso
        {
            find_file_ignore_case sources/install.wim ||
                find_file_ignore_case sources/install.esd ||
                find_file_ignore_case sources/install.swm
        } 2>/dev/null || error_and_exit "can't find install.wim, install.esd or install.swm"
    )

    is_swm=false
    if [[ $(echo "$source_install_wim" | to_lower) = '*.swm' ]]; then
        is_swm=true
        swm_ref=$(
            IFS=. read -r name ext < <(basename "$source_install_wim")
            echo "$name*.$ext"
        )
    fi

    #  iso
    boot_index=$(get_wim_prop "/iso/$sources_boot_wim" 'Boot Index')
    arch_wim=$(get_image_prop "/iso/$sources_boot_wim" "$boot_index" 'Architecture' | to_lower)
    if ! {
        { [ "$(uname -m)" = "x86_64" ] && [ "$arch_wim" = x86_64 ]; } ||
            { [ "$(uname -m)" = "x86_64" ] && [ "$arch_wim" = x86 ]; } ||
            { [ "$(uname -m)" = "aarch64" ] && [ "$arch_wim" = arm64 ]; }
    }; then
        error_and_exit "The machine is $(uname -m), but the iso is $arch_wim."
    fi

    # efi  32  windows
    if is_efi && [ "$arch_wim" = x86 ]; then
        error_and_exit "EFI machine can't install 32-bit Windows."
    fi

    iso_install_wim=/iso/$source_install_wim
    install_wim=/os/installer/$source_install_wim

    # 
    #  Windows 10 Pro  Windows 10 Pro for Workstations
    image_count=$(wiminfo $iso_install_wim | grep "^Image Count:" | cut -d: -f2 | trim)
    all_image_names=$(wiminfo $iso_install_wim | grep ^Name: | sed 's/^Name: *//')
    info "Images Count: $image_count"
    echo "$all_image_names"
    echo

    if [ "$image_count" = 1 ]; then
        # 
        image_name=$all_image_names
        iso_image_index=1
    else
        while true; do
            # 
            # 
            if matched_image_name=$(printf '%s\n' "$all_image_names" | grep -Fix "$image_name"); then
                image_name=$matched_image_name
                iso_image_index=$(wiminfo "$iso_install_wim" "$image_name" | grep 'Index:' | awk '{print $NF}')
                break
            fi

            # 
            file=/image-name
            error "Invalid image name: $image_name"
            echo "Choose a correct image name by one of follow command in ssh to continue:"
            while read -r line; do
                echo "  echo '$line' >$file"
            done < <(echo "$all_image_names")

            # sleep 
            true >$file
            while ! { [ -s $file ] && image_name=$(cat $file) && [ -n "$image_name" ]; }; do
                sleep 1
            done
        done
    fi

    get_selected_image_prop() {
        get_image_prop "$iso_install_wim" "$iso_image_index" "$1"
    }

    # Windows Server ProductType  LanmanNT ?
    # https://cloud.tencent.com/developer/article/2465206
    # https://github.com/search?q=InstallationType+Client+Embedded+Server+Core&type=code
    # https://learn.microsoft.com/azure/virtual-desktop/windows-multisession-faq#why-does-my-application-report-windows-enterprise-multi-session-as-a-server-operating-system

    #  install.wim 
    # Azure  Windows 10/11 Enterprise 
    # HKEY_LOCAL_MACHINE\SOFTWARE\Microsoft\Windows NT\CurrentVersion\InstallationType
    # HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\ProductOptions\ProductType
    # HKEY_LOCAL_MACHINE\SYSTEM\ControlSet001\Control\ProductOptions\ProductSuite

    #                                 InstallationType    ProductType    ProductSuite
    # Windows Client ( Windows)          Client             WinNT        Terminal Server
    # Windows 10/11 Enterprise         Client             ServerNT     Terminal Server
    # Windows Server 2012 R2         Server             ServerNT     Terminal Server  DataCenter ()
    # Windows Server 2012 R2     Server Core        ServerNT     Terminal Server  DataCenter ()
    # Windows Server 2025            Server             ServerNT     Enterprise
    # Windows Server 2025        Server Core        ServerNT     Enterprise
    # WES7 / Thin PC                         Embedded           WinNT        Terminal Server

    mount_iso_install_wim_to() {
        local dir=$1

        mkdir -p "$dir"
        # shellcheck disable=SC2046
        wimmount "$iso_install_wim" "$iso_image_index" "$dir" \
            $($is_swm && echo "--ref=$(dirname "$iso_install_wim")/$swm_ref")
    }

    #  install.wim
    # 1.  sac 
    # 2.  nvme 
    # 3.  sha256
    # 4. Installation Type
    mount_iso_install_wim_to /wim

    # 
    get_windows_version_from_windows_drive /wim

    #  client/server windows 
    #  Hyper-V Server / Azure Stack HCI / Windows Server AC  LTSC 
    windows_type=$(get_windows_type_from_windows_drive /wim)
    product_ver=$(get_windows_name_by_version "$nt_ver" "$build_ver" "$windows_type")

    #  sac  nvme
    {
        find_file_ignore_case /wim/Windows/System32/sacsess.exe && has_sac=true || has_sac=false
        find_file_ignore_case /wim/Windows/System32/drivers/stornvme.sys && has_stornvme=true || has_stornvme=false
    } >/dev/null 2>&1

    #  sha256 
    support_sha256=false
    if is_nt_ver_ge 6.2; then
        support_sha256=true
    else
        #  drvload.exe  sha256 
        #  Windows cannot verify the digital signature for this file.

        # winload.exe/efi 
        # Windows cannot verify the digital signature for this file.
        # strings -e l winload.exe | grep -i signature
        # strings -e l winload.efi | grep -i signature

        #  boot-start  winload.exe/efi 
        #  boot-start  ci.dll 

        # win7 sp1 iso  sha256 
        # ci.dll       8+64  oid 0609608648016503040201 0102040365014886600906
        # winload.exe  8+64  oid 0609608648016503040201 0102040365014886600906
        # winload.efi  8+64  oid     608648016503040201

        #  KB3033929  KB4039648,  2008r2  2008  sha256 
        # https://support.microsoft.com/kb/4472027#:~:text=KB3033929%20%E5%92%8C%20KB4039648
        # https://support.drweb.cn/sha2
        # https://support.kaspersky.com/common/compatibility/15761
        # https://www.internetdownloadmanager.com/register/new_faq/sha256-support-for-outdated-versions-of-Windows.html
        # https://www.catalog.update.microsoft.com/

        # vista sp2 iso
        #  KB4039648  KB4090450  KB 
        #  winload.exe/efi sha256  KB 
        # HKEY_LOCAL_MACHINE\Microsoft\Windows\CurrentVersion\Component Based Servicing\Package
        # HKEY_LOCAL_MACHINE\Microsoft\Windows\CurrentVersion\Component Based Servicing\PackageDetect

        # vista sp2 iso 
        #              BuildLabEx          ubr    winload.exe   winload.efi   ci.dll
        # KB4039648   2018/2/21  6002.18005()     6002.24259    6002.24283    6002.24259
        # KB4039648   2018/3/22  6002.18005()     6002.24259    6002.24298    6002.24259
        # KB4039648-v2  2018/6/12  6002.24381             6002.24362    6002.24381    6002.24259
        # KB4474419-v4  2019/10/8  6003.20555             6003.20505    6003.20555    6003.20593

        # win7 sp1 iso 
        # KB3033929     2015/3/10  7601.18741             18649/22854  18741/22948    18519/22730
        # KB4474419-v3  2019/9/10  7601.24384                   24149        24384          24158

        #  KB4039648 KB3033929  sha256
        # winload.exe/efi  >= ci.dll
        #  winload.exe/efi  sha256

        apk add pev
        local maj min build rev
        winload=$(find_file_ignore_case "/wim/Windows/System32/winload.$(is_efi && echo efi || echo exe)")
        IFS=. read -r maj min build rev \
            < <(peres -v "$winload" | grep 'Product Version:' | awk '{print $NF}')
        apk del pev

        # vista/2008
        # https://support.microsoft.com/kb/KB4039648
        # https://catalog.update.microsoft.com/Search.aspx?q=KB4039648

        # win7/2008r2 
        # https://support.microsoft.com/kb/KB3033929
        # https://catalog.update.microsoft.com/Search.aspx?q=KB3033929

        # rev 1xxxx  GDR 
        # rev 2xxxx  LDR 

        # vista/2008  6002  6003, rev  4000
        # https://support.microsoft.com/topic/1335e4d4-c155-52eb-4a45-b85bd1909ca8

        if is_efi; then
            if { [ "$maj.$min" = 6.1 ] && [ "$build" -eq 7601 ] && [ "$rev" -ge 22948 ]; } ||
                { [ "$maj.$min" = 6.1 ] && [ "$build" -eq 7601 ] && [ "$rev" -ge 18741 ] && [ "$rev" -lt 20000 ]; } ||
                { [ "$maj.$min" = 6.0 ] && [ "$build" -eq 6003 ] && [ "$rev" -ge 20283 ]; } ||
                { [ "$maj.$min" = 6.0 ] && [ "$build" -eq 6002 ] && [ "$rev" -ge 24283 ]; }; then
                support_sha256=true
            fi
        else
            if { [ "$maj.$min" = 6.1 ] && [ "$build" -eq 7601 ] && [ "$rev" -ge 22854 ]; } ||
                { [ "$maj.$min" = 6.1 ] && [ "$build" -eq 7601 ] && [ "$rev" -ge 18649 ] && [ "$rev" -lt 20000 ]; } ||
                { [ "$maj.$min" = 6.0 ] && [ "$build" -eq 6003 ] && [ "$rev" -ge 20259 ]; } ||
                { [ "$maj.$min" = 6.0 ] && [ "$build" -eq 6002 ] && [ "$rev" -ge 24259 ]; }; then
                support_sha256=true
            fi
        fi
    fi

    wimunmount /wim/

    info "Selected image info"
    echo "Image Name: $image_name"
    echo "Product Version: $product_ver"
    echo "Windows Type: $windows_type"
    echo "NT Version: $nt_ver"
    echo "Build Version: $build_ver"
    echo "Revision Version: $rev_ver"
    echo "-------------------------"
    echo "Has SAC: $has_sac"
    echo "Has StorNVMe: $has_stornvme"
    echo "Support SHA256: $support_sha256"
    echo "-------------------------"
    echo

    #  boot.wim  /os
    if [ -n "$boot_wim" ]; then
        #  boot.wim 
        download "$boot_wim" /os/boot.wim
    else
        cp /iso/$sources_boot_wim /os/boot.wim
    fi

    # efi  efi 
    # bios  os 
    if is_efi; then
        boot_dir=/os/boot/efi
    else
        boot_dir=/os
    fi

    #  iso  boot 
    echo 'Copying boot files...'
    find /iso -maxdepth 1 -iname 'boot*' -exec cp -r {} "$boot_dir" \;

    # efi  iso  efi 
    if is_efi; then
        echo 'Copying efi files...'
        find /iso -maxdepth 1 -type d -iname efi -exec cp -r {} "$boot_dir" \;
    fi

    # iso(boot.wim)installer
    echo 'Copying installer files...'
    if false; then
        # 
        rsync -rv \
            --exclude=/sources/boot.wim \
            --exclude=/sources/install.wim \
            --exclude=/sources/install.esd \
            --exclude='/sources/install*.swm' \
            /iso/* /os/installer/
    else
        (
            cd /iso
            find . -type f \
                -not -iname boot.wim \
                -not -iname install.wim \
                -not -iname install.esd \
                -not -iname 'install*.swm' \
                -exec cp -r --parents {} /os/installer/ \;
        )
    fi

    # $iso_image_index  iso  wim 
    # $image_index  installer  wim 

    #  swm wim 
    if $is_swm; then
        install_wim=$(echo "$install_wim" | sed 's/\.swm$/.wim/i')
        # 
        rm -f "$install_wim"
        wimexport --ref="$(dirname "$iso_install_wim")/$swm_ref" "$iso_install_wim" "$iso_image_index" "$install_wim"
        #  image_index  1
        image_index=1
    elif false; then
        #  install.wim
        # :  200M~600M 
        #        boot.wim vista 
        # :  install.wim  10M+
        time wimexport --threads "$(get_build_threads 512)" "$iso_install_wim" "$iso_image_index" "$install_wim"
        #  image_index  1
        image_index=1
        info "install.wim size"
        echo "Original:  $(get_filesize_mb "$iso_install_wim")"
        echo "Optimized: $(get_filesize_mb "$install_wim")"
        echo
    else
        cp "$iso_install_wim" "$install_wim"
        image_index="$iso_image_index"
    fi

    # win11  1GHz 21
    #  install.wim  Installation Type install.wim 
    # 7601.24214.180801-1700.win7sp1_ldr_escrow_CLIENT_ULTIMATE_x64FRE_en-us.iso wim  Installation Type
    # Vista wim    InstallationType
    installation_type_from_install_wim_metadata=$(get_selected_image_prop "Installation Type" 2>/dev/null || true)

    # 
    # https://github.com/pbatard/rufus/issues/1990
    # https://learn.microsoft.com/windows/iot/iot-enterprise/Hardware/System_Requirements
    # win11 24h2 setup.exe /product server  cpu xml

    # windows 11 multi-session  server 2022 "$product_ver"  2022  11
    #  [ "$product_ver" = "11" ]
    if [ "$build_ver" -ge 22000 ] &&
        [ "$(echo "$installation_type_from_install_wim_metadata" | to_lower)" = "client" ] &&
        [ "$(nproc)" -le 1 ]; then
        wiminfo "$install_wim" "$image_index" --image-property WINDOWS/INSTALLATIONTYPE=Server
    fi

    #      
    # arch_uname arch / uname -m                      x86_64   aarch64
    # arch_wim   wiminfo                             x86  x86_64   ARM64
    # arch       virtio iso / unattend.xml / .inf    x86  amd64    arm64
    # arch_xdd   virtio msi / xen                x86   x64
    # arch_dd                               32    64

    #  wim  arch  arch
    case "$arch_wim" in
    x86)
        arch=x86
        arch_xdd=x86
        arch_dd=32
        ;;
    x86_64)
        arch=amd64
        arch_xdd=x64
        arch_dd=64
        ;;
    arm64)
        arch=arm64
        arch_xdd= # xen  arm64 # virtio  arm64 msi
        arch_dd=  #  arm64 
        ;;
    esac

    # win7 drvload  sha256 
    #  windows cannot verify the digital signature for this file
    #  F8 

    add_drivers() {
        info "Add drivers"

        # 
        drv=/os/drivers
        mkdir_clear "$drv"

        # 
        # $(get_cloud_vendor)  cache_dmi_and_virt
        #  $(get_cloud_vendor)  subshell 
        # subshell 
        #  cache_dmi_and_virt
        cache_dmi_and_virt
        vendor="$(get_cloud_vendor)"

        # virtio
        if is_virt_contains virtio; then
            if [ "$vendor" = aliyun ] && is_nt_ver_ge 6.1 && [ "$arch_wim" = x86_64 ]; then
                add_driver_aliyun_virtio
            elif [ "$vendor" = qcloud ] && is_nt_ver_ge 6.1 && [ "$arch_wim" = x86_64 ]; then
                add_driver_qcloud_virtio
            # 
            elif false && [ "$vendor" = huawei ] && is_nt_ver_ge 6.0 && { [ "$arch_wim" = x86 ] || [ "$arch_wim" = x86_64 ]; }; then
                add_driver_huawei_virtio

            # gcp 
            #  windows server  viorng  linux 
            elif [ "$vendor" = gcp ] && is_nt_ver_ge 6.1 && [ "$arch_wim" = x86 ] && $support_sha256; then
                add_driver_gcp_virtio
                add_driver_generic_virtio \( -iname viorng.inf -or -iname pvpanic.inf \)

            elif [ "$vendor" = gcp ] && is_nt_ver_ge 6.1 && [ "$arch_wim" = x86_64 ] && $support_sha256; then
                add_driver_gcp_virtio
                add_driver_generic_virtio -iname viorng.inf

            elif [ "$vendor" = gcp ] && [ "$nt_ver" = 6.1 ] && [ "$arch_wim" = x86_64 ] && ! $support_sha256; then
                add_driver_gcp_virtio_win6_1_sha1_x64
                add_driver_generic_virtio \( -iname viorng.inf -or -iname balloon.inf \)

            else
                # 
                add_driver_generic_virtio
            fi
        fi

        # xen
        if is_virt_contains xen; then
            # generic_xen 
            if is_nt_ver_ge 6.1 && [ "$arch_wim" = x86_64 ]; then
                add_driver_aws_xen
            elif is_nt_ver_ge 6.0 && { [ "$arch_wim" = x86 ] || [ "$arch_wim" = x86_64 ]; }; then
                add_driver_citrix_xen
            fi
        fi

        # vmd
        # RST v17  vmd
        # RST v18 inf  15063 
        # RST v19 inf  15063  v18  id
        # RST v20 inf  19041 
        # RST v21 inf  19041 
        if [ -d /sys/module/vmd ] && [ "$build_ver" -ge 15063 ] && [ "$arch_wim" = x86_64 ]; then
            add_driver_vmd
        fi

        #  IP 
        # root@localhost:~# get_drivers /sys/class/net/eth0
        # hv_netvsc

        #  IP 
        # root@localhost:~# get_drivers /sys/class/net/enP30832s1
        # mana
        # pci_hyperv

        # vpci
        #  linux  pci_hyperv
        # win10 ltsc 2021 boot.wim  vpci.sys azure nvme 
        #  install.wim 
        # PE  pci_hyperv
        if [ -d /sys/module/pci_hyperv ] &&
            get_drivers "/sys/block/$xda" | grep -qx pci_hyperv &&
            ! find_file_ignore_case /wim/Windows/System32/drivers/vpci.sys >/dev/null 2>&1; then
            add_driver_vpci
        fi

        # 
        case "$vendor" in
        aws)
            if is_nt_ver_ge 6.1 && { [ "$arch_wim" = x86_64 ] || [ "$arch_wim" = arm64 ]; }; then
                add_driver_aws
            fi
            ;;
        azure)
            # inf 
            if [ "$arch_wim" = x86 ] || [ "$arch_wim" = x86_64 ]; then
                add_driver_azure
            fi
            ;;
        gcp)
            # inf 6.0 
            # x86 x86_64 arm64 
            add_driver_gcp
            ;;
        esac

        # intel 
        #  vista/2008 
        # win7  inf/ndis  vista/2008
        if is_nt_ver_ge 6.1 && { [ "$arch_wim" = x86 ] || [ "$arch_wim" = x86_64 ]; } &&
            grep -iq 8086 /sys/class/net/e*/device/vendor; then
            add_driver_intel_nic
        fi

        # 
        add_driver_custom
    }

    add_driver_intel_nic() {
        info "Add drivers: Intel NIC"

        arch_intel=$(
            case "$arch_wim" in
            x86) echo 32 ;;
            x86_64) echo x64 ;;
            esac
        )

        url=$(
            case "$product_ver" in
            '7' | '2008 r2')
                #  25.0
                # 25.0  24.5  ProSet 
                # 25.0  sha256 
                # 24.3  sha1 
                # https://web.archive.org/web/20250405130938/https://www.intel.com/content/www/us/en/download/15590/29323/intel-network-adapter-driver-for-windows-7-final-release.html
                echo https://downloadmirror.intel.com/18713/eng/prowin${arch_intel}legacy.exe
                ;;
            '8' | '8.1')
                #  Intel® Network Adapter Driver for Windows 8* - Final Release  22.7.1
                # 
                # https://web.archive.org/web/20250501043104/https://www.intel.com/content/www/us/en/download/16765/intel-network-adapter-driver-for-windows-8-final-release.html
                # 27.8  NDIS63  Windows 8
                # 27.8  22.7.1
                echo https://downloadmirror.intel.com/764813/Wired_driver_27.8_${arch_intel}.zip
                ;;
            '2012' | '2012 r2')
                echo https://downloadmirror.intel.com/772074/Wired_driver_28.0_${arch_intel}.zip
                ;;
            # 2016 2019 2022 2025 win10 win11
            *) case "${arch_intel}" in
                32)
                    echo https://downloadmirror.intel.com/849483/Wired_driver_30.0.1_${arch_intel}.zip
                    ;;
                x64)
                    id=$(
                        case "$product_ver" in
                        10) echo 18293 ;;
                        11) echo 727998 ;;
                        2016) echo 18737 ;;
                        2019) echo 19372 ;;
                        2022) echo 706171 ;;
                        2025) echo 838943 ;;
                        esac
                    )
                    get_intel_download_url "$id" "(Wired_driver|prowin).*${arch_intel}(legacy)?\.(zip|exe)"
                    ;;
                esac ;;
            esac
        )

        #  intel  aria2 
        #  aws waf js  aws-waf-token cookie 
        download_via_browser "$url" $drv/intel.zip

        # inf  UTF-16 LE rg 
        #  busybox unzip  win10 
        #  28.0 
        #  convert_backslashes
        apk add unzip ripgrep

        # https://superuser.com/questions/1382839/zip-files-expand-with-backslashes-on-linux-no-subdirectories
        convert_backslashes() {
            for file in "$1"/*\\*; do
                if [ -f "$file" ]; then
                    target="${file//\\//}"
                    mkdir -p "${target%/*}"
                    mv -v "$file" "$target"
                fi
            done
        }

        # win7  .exe 
        # win10  .zip  zip 
        #  windows  win8  checksum 
        unzip -o -d $drv/intel/ $drv/intel.zip || true
        convert_backslashes $drv/intel

        is_have_inf_in_intel_dir() {
            find $drv/intel -ipath "*/*.inf" | grep . >/dev/null
        }

        # Wired_driver_28.0_x64.zip 
        if ! is_have_inf_in_intel_dir; then
            unzip -o -d $drv/intel/ $drv/intel/Wired_driver_*.exe || true
            convert_backslashes $drv/intel
        fi

        #  || true inf 
        if ! is_have_inf_in_intel_dir; then
            error_and_exit "No .inf file found in intel driver package"
        fi

        # Vista RTM  6000    NDIS 6.0
        # 2008  RTM  6001    NDIS 6.1

        # 
        # 1.  windows client/server
        #    
        # 2.  win10  RS5 1809 NDIS65  10240
        # 3.  NDIS65  NDIS 6.51
        # https://learn.microsoft.com/en-us/windows-hardware/drivers/network/overview-of-ndis-versions
        min_support_map=$(cat <<EOF |
6000  NDIS60
6001  NDIS61
7600  NDIS62
9200  NDIS63
9600  NDIS64
10240 NDIS65
14393 NDIS66
15063 NDIS67
16299 NDIS68
20348 WS2022
22000 W11
26100 WS2025
EOF
            case "$windows_type" in
            client) grep -E ' (NDIS|W)[0-9]' ;;
            server) grep -E ' (NDIS|WS)[0-9]' ;;
            esac)

        for ethx in $(get_eths); do
            sys_dir=$(get_sys_dir_for_eth $ethx)
            ven=$(cat $sys_dir/vendor | sed 's/^0x//')
            dev=$(cat $sys_dir/device | sed 's/^0x//')
            subsys=$(cat $sys_dir/subsystem_device $sys_dir/subsystem_vendor | sed 's/^0x//' | tr -d '\n')
            rev=$(cat $sys_dir/revision | sed 's/^0x//')

            info "intel nic"
            echo "Ethernet: $ethx"
            echo "Vendor: $ven"
            echo "Device: $dev"
            echo "Subsystem: $subsys"
            echo "Revision: $rev"

            compatible_ids="VEN_$ven&DEV_$dev&SUBSYS_$subsys&REV_$rev"
            compatible_ids="$compatible_ids|VEN_$ven&DEV_$dev&SUBSYS_$subsys"
            compatible_ids="$compatible_ids|VEN_$ven&DEV_$dev&REV_$rev"
            compatible_ids="$compatible_ids|VEN_$ven&DEV_$dev"

            while read -r min_ver ndis; do
                if [ "$build_ver" -ge "$min_ver" ]; then
                    #  PE?
                    #    intel\Release_30.0.zip\PROXGB\Win32\NDIS68\WinPE\*.inf
                    #  intel\Release_30.0.zip\PROXGB\Win32\NDIS68\*.inf

                    # find  $drv/intel  0
                    # rg  -E
                    #  WinPE 
                    if infs=$(find $drv/intel -ipath "*/Win$arch_intel/$ndis/*.inf" -exec rg -iwl "$compatible_ids" {} \; | grep . ||
                        find $drv/intel -ipath "*/Win$arch_intel/$ndis/WinPE/*.inf" -exec rg -iwl "$compatible_ids" {} \; | grep .); then
                        for inf in $infs; do
                            cp_drivers $inf
                        done
                        break
                    fi
                fi
            done < <(echo "$min_support_map" | tac) # 
        done

        apk del unzip ripgrep
    }

    # aws nitro
    # https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/aws-nvme-drivers.html
    # https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/enhanced-networking-ena.html
    add_driver_aws() {
        info "Add drivers: AWS"

        #  win7  sha256 
        nvme_ver=$(
            case "$nt_ver" in
            6.1) echo 1.3.2 ;; # sha1 
            6.2 | 6.3) echo 1.5.1 ;;
            *) echo Latest ;;
            esac
        )

        ena_ver=$(
            case "$nt_ver" in
            6.1) $support_sha256 && echo 2.2.3 || echo 2.1.4 ;;
            6.2 | 6.3) echo 2.6.0 ;;
            *) echo Latest ;;
            esac
        )

        [ "$arch_wim" = arm64 ] && arch_dir=/ARM64 || arch_dir=

        # arm64  AWSNVMe.zip 
        if ! [ "$arch_wim" = arm64 ]; then
            download "$(get_aws_repo)/NVMe$arch_dir/$nvme_ver/AWSNVMe.zip" $drv/AWSNVMe.zip
            unzip -o -d $drv/aws/ $drv/AWSNVMe.zip
        fi

        download "$(get_aws_repo)/ENA$arch_dir/$ena_ver/AwsEnaNetworkDriver.zip" $drv/AwsEnaNetworkDriver.zip
        unzip -o -d $drv/aws/ $drv/AwsEnaNetworkDriver.zip

        cp_drivers $drv/aws
    }

    # citrix xen
    add_driver_citrix_xen() {
        info "Add drivers: Citrix Xen"

        apk add 7zip
        download https://s3.amazonaws.com/ec2-downloads-windows/Drivers/Citrix-Win_PV.zip $drv/Citrix-Win_PV.zip
        unzip -o -d $drv $drv/Citrix-Win_PV.zip
        case "$arch_wim" in
        x86) override=s ;;    # skip
        x86_64) override=a ;; # always
        esac
        #  $PLUGINSDIR $TEMP
        exclude='$*'
        7z x $drv/Citrix_xensetup.exe -o$drv/xen/ -ao$override -x!$exclude

        cp_drivers $drv/xen
    }

    # aws xen
    # https://docs.aws.amazon.com/AWSEC2/latest/WindowsGuide/xen-drivers-overview.html
    add_driver_aws_xen() {
        info "Add drivers: AWS Xen"

        apk add msitools

        # 8.4.3+  xenbus 
        #  windows  8.4.3+
        #  linux  8.4.3+

        #  linux +  8.4.3
        #  msi  xenbus
        #  inf  xenbus

        apk add lscpu
        hypervisor_vendor=$(lscpu | grep 'Hypervisor vendor:' | awk '{print $3}')
        apk del lscpu

        aws_pv_ver=$(
            case "$nt_ver" in
            6.1) $support_sha256 && echo 8.3.5 || echo 8.3.2 ;;
            6.2 | 6.3)
                case "$hypervisor_vendor" in
                Xen) echo 8.3.5 ;;       #  Linux
                Microsoft) echo 8.4.3 ;; #  Windows
                esac
                ;;
            *)
                case "$hypervisor_vendor" in
                Xen) echo 8.3.5 ;;        #  Linux
                Microsoft) echo Latest ;; #  Windows
                esac
                ;;
            esac
        )

        url=$(
            case "$aws_pv_ver" in
            8.3.2) echo https://web.archive.org/web/20221016194548/https://s3.amazonaws.com/ec2-windows-drivers-downloads/AWSPV/$aws_pv_ver/AWSPVDriver.zip ;; # win7 sha1
            *) echo "$(get_aws_repo)/AWSPV/$aws_pv_ver/AWSPVDriver.zip" ;;
            esac
        )

        download "$url" $drv/AWSPVDriver.zip

        unzip -o -d $drv $drv/AWSPVDriver.zip
        mkdir -p $drv/xen/
        msiextract $drv/AWSPVDriverSetup.msi -C $drv/xen/

        cp_drivers $drv/xen/.Drivers
    }

    # citrix xen
    # https://pvupdates.vmd.citrix.com/updates.json 7.2.0.1555
    # https://pvupdates.vmd.citrix.com/updates.v9.json 9.3.3.125
    # https://pvupdates.vmd.citrix.com/autoupdate.v1.json 9.3.3.125
    # https://pvupdates.vmd.citrix.com/autoupdate.v2.json 9.4.0.146
    # https://support.citrix.com/s/article/CTX235403-updates-to-xenserver-vm-tools-for-windows-for-xenserver-and-citrix-hypervisor

    # 
    # 2012 r2   9.3.1
    # 2012      9.3.0
    # 2008 (r2) 7.2.0.1555

    # 9.3.1
    # https://downloads.xenserver.com/vm-tools-windows/9.3.1/managementagentx64.msi
    # http://downloadns.citrix.com.edgesuite.net/17461/managementagentx64.msi

    # 7.2.0.1555
    # http://downloadns.citrix.com.edgesuite.net/14656/managementagentx64.msi
    # http://downloadns.citrix.com.edgesuite.net/14655/managementagentx86.msi

    # xen
    # aws
    # https://lore.kernel.org/xen-devel/E1qKMmq-00035B-SS@xenbits.xenproject.org/
    # https://xenbits.xenproject.org/pvdrivers/win/
    #  aws t2  xenbus 7
    #  aws awsxen
    add_driver_generic_xen() {
        info "Add drivers: Generic Xen"

        parts='xenbus xencons xenhid xeniface xennet xenvbd xenvif xenvkbd'
        mkdir -p $drv/xen/
        for part in $parts; do
            download https://xenbits.xenproject.org/pvdrivers/win/$part.tar $drv/$part.tar
            tar -xf $drv/$part.tar -C $drv/xen/
        done

        cp_drivers $drv/xen -ipath "*/$arch_xdd/*"
    }

    # virtio
    # https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/
    add_driver_generic_virtio() {
        info "Add drivers: Generic virtio"

        #  win10 / win11  NT  10.0
        # https://github.com/virtio-win/kvm-guest-drivers-windows/commit/9af43da9e16e2d4bf4ea4663cdc4f29275fff48f
        # vista >>> 2k8
        # 10 >>> w10
        # 2012 r2 >>> 2k12R2
        virtio_sys=$(
            #  vista 
            if [ "$product_ver" = vista ]; then
                echo 2k8

            # 2k16 2k19 2k22  arm64 
            elif { [ "$product_ver" = 2016 ] || [ "$product_ver" = 2019 ] || [ "$product_ver" = 2022 ]; } &&
                [ "$arch_wim" = arm64 ]; then
                echo w10

            else
                case "$windows_type" in
                client) echo "w$product_ver" ;;
                server) echo "$product_ver" | sed -E -e 's/ //' -e 's/^200?/2k/' -e 's/r2/R2/' ;;
                esac
            fi
        )

        # win7-drivers  win7  173 
        # 1. 2020.1.24 https://github.com/virtio-win/virtio-win-pkg-scripts/tree/win7-drivers/data/old-drivers/Win7

        # master  win7  3 
        # https://github.com/virtio-win/virtio-win-pkg-scripts/commits/master/data/old-drivers/Win7
        # 1. 2020/6/4  sha256176  176 iso
        # 2. 2020/8/10  17400 189~215 iso
        # 3. 2022/4/14  217~ iso

        #  github commit  win7 173(sha1) 176(sha256) 
        #  jsdelivr  github

        # 2k12
        # https://github.com/virtio-win/virtio-win-pkg-scripts/issues/61
        # 217 ~ 271    2k12  virtio-win-1.9.45 

        # win7
        # https://fedorapeople.org/groups/virt/virtio-win/repo/stable/
        # https://github.com/virtio-win/virtio-win-pkg-scripts/issues/40
        # 171-1     sha1   
        # 173-9     sha1    win7-drivers  win7 + sha1?
        # 176       sha256  master-1   win7 sha256 iso iso 
        # 185 ~ 187 sha256 win7  176
        # 189 ~ 215 sha1    master-2   17400vultr 
        # 217 ~ 271 sha1    master-3   vioscsi  ID  virtio-win-1.9.45 

        #  vioscsi  ID  PCI\VEN_1AF4&DEV_1004&SUBSYS_0008108E&REV_00
        # SUBSYS  ID 

        # virtio-win-0.1.173-9
        # %VirtioScsi.DeviceDesc% = scsi_inst, PCI\VEN_1AF4&DEV_1004&SUBSYS_00081AF4&REV_00, PCI\VEN_1AF4&DEV_1004
        # %VirtioScsi.DeviceDesc% = scsi_inst, PCI\VEN_1AF4&DEV_1048&SUBSYS_11001AF4&REV_01, PCI\VEN_1AF4&DEV_1048

        # stable-virtio
        # %RHELScsi.DeviceDesc% = rhelscsi_inst, PCI\VEN_1AF4&DEV_1004&SUBSYS_00081AF4&REV_00
        # %RHELScsi.DeviceDesc% = rhelscsi_inst, PCI\VEN_1AF4&DEV_1048&SUBSYS_11001AF4&REV_01

        local baseurl=https://fedorapeople.org/groups/virt/virtio-win/direct-downloads

        case "$nt_ver" in
        6.0 | 6.1) $support_sha256 &&
            dir=archive-virtio/virtio-win-0.1.187-1 ||
            dir=archive-virtio/virtio-win-0.1.173-9 ;;        # vista|w7|2k8|2k8R2
        6.2 | 6.3) dir=archive-virtio/virtio-win-0.1.215-2 ;; # w8|w8.1|2k12|2k12R2
        *)
            # 
            #  stable-virtio 

            # https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/
            #  anubis 

            # https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/CHECKSUM
            #  anubis 
            dir=$(wget --spider -S "$baseurl/stable-virtio/CHECKSUM" 2>&1 >/dev/null |
                grep -E '^  Location: ' | grep -Ewo -m1 'archive-virtio/virtio-win-[^/]+')
            # dir=stable-virtio
            ;;
        esac

        #  dir 
        if [[ "$dir" =~ [0-9] ]]; then
            local can_use_cn_mirror=true
        else
            local can_use_cn_mirror=false
        fi

        # vista|w7|2k8|2k8R2|arm64  iso 
        if [ "$nt_ver" = 6.0 ] || [ "$nt_ver" = 6.1 ] || [ "$arch_wim" = arm64 ]; then
            virtio_source=iso
        else
            virtio_source=msi
        fi

        if [ "$virtio_source" = iso ]; then
            download $baseurl/$dir/virtio-win.iso $drv/virtio.iso $can_use_cn_mirror
            mkdir -p $drv/virtio
            mount -o ro $drv/virtio.iso $drv/virtio

            # vista  windows could not configure one or more system components
            # 2008 
            if [ "$product_ver" = vista ]; then
                cp_drivers $drv/virtio -ipath "*/$virtio_sys/$arch/*" "$@" -not -ipath "*/balloon/*"
            else
                cp_drivers $drv/virtio -ipath "*/$virtio_sys/$arch/*" "$@"
            fi
        else
            apk add 7zip file
            download $baseurl/$dir/virtio-win-gt-$arch_xdd.msi $drv/virtio.msi $can_use_cn_mirror
            match="FILE_*_${virtio_sys}_${arch}*"
            7z x $drv/virtio.msi -o$drv/virtio -i!$match -y -bb1
            (
                cd $drv/virtio

                # 
                echo "Recognizing file extension..."
                for file in *"${virtio_sys}_${arch}"; do
                    recognized=false
                    maybe_exts=$(file -b --extension "$file")

                    # exe/sys -> sys
                    # exe/com -> exe
                    # dll/cpl/tlb/ocx/acm/ax/ime -> dll
                    for ext in sys exe dll; do
                        if echo $maybe_exts | grep -qw $ext; then
                            recognized=true
                            mv -v "$file" "$file.$ext"
                            break
                        fi
                    done

                    # 
                    # 
                    if ! $recognized; then
                        rm -fv "$file"
                    fi
                done

                # 
                # FILE_netkvm_netkvmco_w8.1_amd64.dll
                # FILE_netkvm_w8.1_amd64.cat
                # 
                # netkvmco.dll
                # netkvm.cat
                echo "Renaming files..."
                for file in *; do
                    new_file=$(echo "$file" | sed "s|FILE_||; s|_${virtio_sys}_${arch}||; s|.*_||")
                    mv -v "$file" "$new_file"
                done
            )
            cp_drivers $drv/virtio "$@"
        fi
    }

    add_driver_qcloud_virtio() {
        info "Add drivers: QCloud virtio"

        # ?
        # https://mirrors.tencent.com/install/cts/windows/Drivers.zip

        apk add 7zip
        download https://mirrors.tencent.com/install/windows/virtio_64_1.0.9.exe $drv/virtio.exe true
        exclude='$*' #  $PLUGINSDIR
        override=u   # A(u)to rename all
        7z x $drv/virtio.exe -o$drv/qcloud/ -ao$override -x!$exclude

        # balloon     6.2
        # balloon_1   6.1

        # netkvm      10.0
        # netkvm_1    6.1
        # netkvm_2    6.3

        # viostor     10.0
        # viostor_1   6.1
        # viostor_2   6.2

        drivers=$(
            case "$nt_ver" in
            6.1) echo balloon_1 netkvm_1 viostor_1 ;; # sha1
            6.2) echo balloon netkvm_1 viostor_2 ;;
            6.3) echo balloon netkvm_2 viostor_2 ;;
            *) echo balloon netkvm viostor ;;
            esac
        )

        for old_name in $drivers; do
            part=${old_name%%_*}
            if ! [ "$old_name" = "$part" ]; then
                find $drv/qcloud/$part -type f -iname "$old_name.*" | while read -r file; do
                    ext="${file##*.}"
                    mv -v "$file" "$drv/qcloud/$part/$part.$ext"
                done
            fi
            cp_drivers $drv/qcloud/$part/$part.inf
        done
    }

    add_driver_huawei_virtio() {
        info "Add drivers: Huawei virtio"

        huawei_sys=$(
            case "$(echo "$product_ver" | to_lower)" in
            vista) echo Vista2008 ;;
            7) echo 7 ;;
            8) [ "$arch_wim" = x86 ] && echo 7 || echo 2012 ;;      #  win8 32/64
            8.1) [ "$arch_wim" = x86 ] && echo 7 || echo 2012_R2 ;; #  win8.1 32/64
            10 | 11) echo 10 ;;
            2008) echo Vista2008 ;;
            '2008 r2') echo 2008_R2 ;;
            2012) [ "$arch_wim" = x86 ] && echo 2008_R2 || echo 2012 ;; #  2012 32
            '2012 r2') echo 2012_R2 ;;
            2016 | 2019 | 202*) echo 2016 ;;
            esac
        )

        download https://ecs-instance-driver.obs.cn-north-1.myhuaweicloud.com/vmtools-windows.zip $drv/vmtools-windows.zip
        unzip -o -d $drv $drv/vmtools-windows.zip
        mkdir -p $drv/huawei
        mount -o ro $drv/vmtools-windows.iso $drv/huawei

        cp_drivers $drv/huawei -ipath "*/upgrade/windows ${huawei_sys}_${arch_dd}/drivers/*"
    }

    add_driver_aliyun_virtio() {
        info "Add drivers: Aliyun virtio"

        aliyun_sys=$(
            case "$nt_ver" in
            6.1) echo 2008R2 ;;
            6.2 | 6.3) echo 2012R2 ;; #  2012 
            *) echo 2016 ;;
            esac
        )

        subdir=
        if [ "$nt_ver" = 6.1 ] && ! $support_sha256; then
            subdir=58017/ # sha1
        fi

        region=cn-hangzhou

        download https://windows-driver-$region.oss-$region.aliyuncs.com/virtio/${subdir}AliyunVirtio_WIN$aliyun_sys.zip \
            $drv/AliyunVirtio.zip
        unzip -o -d $drv $drv/AliyunVirtio.zip

        apk add innoextract
        innoextract -d $drv/aliyun/ $drv/AliyunVirtio_*_WIN${aliyun_sys}_$arch_xdd.exe
        apk del innoextract

        cp_drivers $drv/aliyun -ipath "*/C$/Program Files/AliyunVirtio/*/drivers/*"
    }

    # gcp virtio win7 x64 sha1
    #  balloon viorng
    add_driver_gcp_virtio_win6_1_sha1_x64() {
        info "Add drivers: GCP virtio win6.1 sha1 x64"

        #  nvme  nvme 
        #  win7  nvme 
        #  nvme 
        # (google-compute-engine-driver-nvme 2.0.0  nvme )
        mkdir -p $drv/gce/win6.1sha1
        for file in \
            WdfCoInstaller01009.dll WdfCoInstaller01011.dll \
            netkvm.inf netkvm.cat netkvm.sys netkvmco.dll \
            pvpanic.inf pvpanic.sys pvpanic.cat \
            vioscsi.inf vioscsi.sys vioscsi.cat \
            $([ -d /sys/module/nvme ] && ! $has_stornvme && echo nvme.inf nvme64.cat nvme.sys); do
            download https://storage.googleapis.com/gce-windows-drivers-public/win6.1sha1/$file $drv/gce/win6.1sha1/$file
        done
        cp_drivers $drv/gce/win6.1sha1
    }

    # gcp virtio win7+ sha256
    # x86  viorng pvpanic
    # x64  viorng
    # https://github.com/GoogleCloudPlatform/compute-image-tools/tree/master/daisy_workflows/image_build/windows
    #  https://console.cloud.google.com/storage/browser/gce-windows-drivers-public  googet 
    #  googet 
    add_driver_gcp_virtio() {
        info "Add drivers: GCP virtio"

        mkdir -p $drv/gce
        gce_repo=https://packages.cloud.google.com/yuck
        download $gce_repo/repos/google-compute-engine-stable/index $drv/gce/gce.json
        for part in balloon netkvm pvpanic vioscsi; do
            # gcp  pvpanic  x86 
            if [ "$part" = pvpanic ] && [ "$arch_wim" = x86 ]; then
                continue
            fi

            mkdir -p $drv/gce/$part
            link=$(grep -o "/pool/.*-google-compute-engine-driver-$part.*\.goo" $drv/gce/gce.json)
            wget $gce_repo$link -O- | tar xz -C $drv/gce/$part

            [ "$arch_wim" = x86 ] && suffix=-32 || suffix=
            cp_drivers $drv/gce/$part -ipath "*/win$nt_ver$suffix/*"
        done
    }

    # gcp
    # x86 x86_64 arm64 
    # win7  sha256 
    add_driver_gcp() {
        info "Add drivers: GCP"

        # https://packages.cloud.google.com/yuck/repos/google-compute-engine-stable/index
        # https://packages.cloud.google.com/yuck/repos/google-compute-engine-driver-gvnic-gq-stable/index
        #  gvnic  gvnic-gq-stable ?

        mkdir -p $drv/gce
        gce_repo=https://packages.cloud.google.com/yuck
        download $gce_repo/repos/google-compute-engine-stable/index $drv/gce/gce.json
        for part in gvnic gga; do
            # gvnic  arm64
            if [ "$part" = gvnic ] && [ "$arch_wim" = arm64 ]; then
                continue
            fi

            mkdir -p $drv/gce/$part
            link=$(grep -o "/pool/.*-google-compute-engine-driver-$part.*\.goo" $drv/gce/gce.json)
            wget $gce_repo$link -O- | tar xz -C $drv/gce/$part

            # inf 
            #  win7 gvnic ndis  6.2vista/2008 
            # https://github.com/GoogleCloudPlatform/compute-virtual-ethernet-windows/blob/cad1edf7a05465f4972a81f2c015952fd228b5e3/src/gvnic.vcxproj#L298
            if false; then
                for suffix in '' '-32'; do
                    if [ -d "$drv/gce/$part/win6.1$suffix" ]; then
                        cp -r "$drv/gce/$part/win6.1$suffix" "$drv/gce/$part/win6.0$suffix"
                    fi
                done
            fi

            case "$part" in
            gvnic)
                [ "$arch_wim" = x86 ] && suffix=-32 || suffix=
                cp_drivers $drv/gce/gvnic -ipath "*/win$nt_ver$suffix/*"
                ;;
            gga)
                cp_drivers $drv/gce/gga -ipath "*/win$nt_ver/*"
                ;;
            esac
        done
    }

    # azure
    # https://learn.microsoft.com/azure/virtual-network/accelerated-networking-mana-windows
    add_driver_azure() {
        info "Add drivers: Azure"

        download https://aka.ms/manawindowsdrivers $drv/azure.zip
        unzip $drv/azure.zip -d $drv/azure/
        cp_drivers $drv/azure
    }

    # vpci
    add_driver_vpci() {
        info "Add drivers: vpci"

        mount_iso_install_wim_to /wim-tmp

        #  install.wim  vpci 
        if vpci_sys=$(find_file_ignore_case /wim-tmp/Windows/System32/drivers/vpci.sys) &&
            wvpci_inf=$(find_file_ignore_case /wim-tmp/Windows/INF/wvpci.inf); then

            # 
            from_system_hive="$(find_file_ignore_case /wim-tmp/Windows/System32/config/SYSTEM)"
            from_software_hive="$(find_file_ignore_case /wim-tmp/Windows/System32/config/SOFTWARE)"
            to_system_hive="$(find_file_ignore_case /wim/Windows/System32/config/SYSTEM)"
            to_software_hive="$(find_file_ignore_case /wim/Windows/System32/config/SOFTWARE)"

            apk add hivex-perl

            #  wvpci.inf 
            #  wvpci.inf_amd64_86afbe8940682d27 
            wvpci_inf_filename_with_hash=$(hivexget "$from_system_hive" 'DriverDatabase\DriverInfFiles\wvpci.inf' Active)

            # .inf .sys
            cp -fv "$vpci_sys" "$(get_path_in_correct_case /wim/Windows/System32/drivers/)"
            cp -fv "$wvpci_inf" "$(get_path_in_correct_case /wim/Windows/INF/)"
            cp -rfv "$(get_path_in_correct_case "/wim-tmp/Windows/System32/DriverStore/FileRepository/$wvpci_inf_filename_with_hash/")" \
                "$(get_path_in_correct_case /wim/Windows/System32/DriverStore/FileRepository/)"

            # .cat
            apk add binutils
            for file in "$(get_path_in_correct_case '/wim-tmp/Windows/System32/CatRoot/{F750E6C3-38EE-11D1-85E5-00C04FC295EE}/')"*; do
                if strings -e l "$file" | grep -Fiq vpci.sys; then
                    cp -fv "$file" "$(get_path_in_correct_case '/wim/Windows/System32/CatRoot/{F750E6C3-38EE-11D1-85E5-00C04FC295EE}/')"
                fi
            done
            apk del binutils

            mkdir -p "$drv/vpci"

            # SOFTWARE
            reg=$drv/vpci/software.reg
            # shellcheck disable=SC2043
            for key in \
                "Microsoft\Windows\CurrentVersion\Setup\PnpLockdownFiles\%SystemRoot%/System32/drivers/vpci.sys"; do
                hivexregedit --export "$from_software_hive" "$key" >>"$reg"
            done
            hivexregedit --merge "$to_software_hive" "$reg"

            # SYSTEM
            #  HKEY_LOCAL_MACHINE\SYSTEM\Select  Current/Default  ControlSet 
            reg=$drv/vpci/system.reg
            for key in \
                "ControlSet001\Services\EventLog\System\vpci" \
                "ControlSet001\Services\vpci" \
                "DriverDatabase\DeviceIds\VMBUS\{44C4F61D-4444-4400-9D52-802E27EDE19F}" \
                "DriverDatabase\DriverInfFiles\wvpci.inf" \
                "DriverDatabase\DriverPackages\\$wvpci_inf_filename_with_hash"; do
                hivexregedit --export "$from_system_hive" "$key" >>"$reg"
            done
            #  Tag 
            # HKEY_LOCAL_MACHINE\System\ControlSet001\Control\GroupOrderList  System Bus Extender
            #  vpci  tag tag 
            cat <<EOF >>"$reg"
[\ControlSet001\Services\vpci]
"Tag"=-
EOF
            hivexregedit --merge "$to_system_hive" "$reg"

            apk del hivex-perl
        else
            error_and_exit "vpci driver not found."
        fi

        wimunmount /wim-tmp
    }

    add_driver_vmd() {
        info "Add drivers: VMD"

        local id=
        for d in /sys/bus/pci/devices/*; do
            if [ "$(cat "$d/vendor" 2>/dev/null)" = "0x8086" ] &&
                device=$(sed 's/^0x//' "$d/device" 2>/dev/null); then

                # v21
                if [ "$build_ver" -ge 19041 ] &&
                    [ "$device" = "b06f" ]; then
                    id=920456
                    break

                # v20
                elif [ "$build_ver" -ge 19041 ] &&
                    { [ "$device" = "467f" ] ||
                        [ "$device" = "a77f" ] ||
                        [ "$device" = "7d0b" ] ||
                        [ "$device" = "ad0b" ]; }; then
                    id=849936
                    break

                # v19
                elif [ "$build_ver" -ge 15063 ] &&
                    { [ "$device" = "9a0b" ] ||
                        [ "$device" = "467f" ] ||
                        [ "$device" = "a77f" ]; }; then
                    id=849933
                    break
                fi
            fi
        done

        if [ -n "$id" ]; then
            local url
            url=$(get_intel_download_url "$id" "SetupRST\.exe")

            #  intel  aria2 
            download_via_browser $url $drv/SetupRST.exe
            apk add 7zip
            7z x $drv/SetupRST.exe -o$drv/SetupRST -i!.text
            7z x $drv/SetupRST/.text -o$drv/vmd
            apk del 7zip
            cp_drivers $drv/vmd
        else
            #  vmd  vmd linux  vmd ?
            #  vmd  vmd 
            # 
            : error_and_exit "can't find suitable vmd driver"
        fi
    }

    # 
    #  win7  win10 
    #  win10  win7 
    #  win10 
    #  win7 
    # 

    add_driver_custom() {
        if [ -d /custom_drivers/ ]; then
            cp_drivers custom /custom_drivers/
            # 
        fi
    }

    # 
    apk add xmlstarlet
    download $confhome/windows.xml /tmp/autounattend.xml
    locale=$(get_selected_image_prop 'Default Language')
    use_default_rdp_port=$(is_need_change_rdp_port && echo false || echo true)

    # 7601.24214.180801-1700.win7sp1_ldr_escrow_CLIENT_ULTIMATE_x64FRE_en-us.iso Image Name 
    #  xml Image Name 
    sed -i \
        -e "s|%arch%|$arch|" \
        -e "s|%image_name%|$image_name|" \
        -e "s|%locale%|$locale|" \
        -e "s|%use_default_rdp_port%|$use_default_rdp_port|" \
        /tmp/autounattend.xml

    # 
    if is_administrator_username "$username"; then
        # Administrator
        password_base64=$(get_password_windows_administrator_base64)
        xmlstarlet ed -L -N x="urn:schemas-microsoft-com:unattend" \
            -d "//x:LocalAccounts" \
            /tmp/autounattend.xml
        sed -i \
            -e "s|%enable_administrator%|1|gi" \
            -e "s|%administrator_password%|$password_base64|gi" \
            /tmp/autounattend.xml
    else
        # 
        password_base64=$(get_password_windows_user_base64)
        xmlstarlet ed -L -N x="urn:schemas-microsoft-com:unattend" \
            -d "//x:AdministratorPassword" \
            /tmp/autounattend.xml
        sed -i \
            -e "s|%enable_administrator%|0|gi" \
            -e "s|%user_username%|$username|gi" \
            -e "s|%user_password%|$password_base64|gi" \
            /tmp/autounattend.xml
    fi

    # 
    if is_efi; then
        sed -i "s|%installto_partitionid%|3|" /tmp/autounattend.xml
    else
        sed -i "s|%installto_partitionid%|1|" /tmp/autounattend.xml
    fi

    # vista/2008 
    if [ "$nt_ver" = 6.0 ]; then
        sed -i "/EnableFirewall/d" /tmp/autounattend.xml
    fi

    # 2012 r2 key  Windows cannot read the <ProductKey> setting from the unattend answer file ei.cfg
    # ltsc 2021 ei.cfg key 
    # ltsc 2021 n ei.cfg key  Windows Cannot find Microsoft software license terms
    #  iso ei.cfg  EVAL  key  Windows Cannot find Microsoft software license terms

    # key
    if [ "$product_ver" = vista ]; then
        # vista  edition 
        # https://learn.microsoft.com/en-us/windows-server/get-started/kms-client-activation-keys
        # 
        setup_cfg=$(get_path_in_correct_case /os/installer/sources/inf/setup.cfg)
        key=$(del_cr <"$setup_cfg" | grep -Eix 'Value=([A-Z0-9]{5}-){4}[A-Z0-9]{5}' | cut -d= -f2 | grep .)
        sed -i "s/%key%/$key/" /tmp/autounattend.xml
    else
        if [ -f "$(get_path_in_correct_case /os/installer/sources/ei.cfg)" ]; then
            #  ei.cfg key 
            sed -i "/%key%/d" /tmp/autounattend.xml
        else
            #  ei.cfg key
            sed -i "s/%key%//" /tmp/autounattend.xml
        fi
    fi

    #  boot.wim
    info "mount boot.wim"
    wimmountrw /os/boot.wim "$boot_index" /wim/

    # 
    copyed_infs=
    cp_drivers() {
        if [ "$1" = custom ]; then
            shift
            dst=$(get_path_in_correct_case "/wim/custom_drivers")
        else
            dst=$(get_path_in_correct_case "/wim/drivers")
        fi

        src=$1
        shift

        # -not -iname "*.pdb" \
        # -not -iname "dpinst.exe" \

        #  while  $copyed_infs find | while
        while read -r inf; do
            if ! is_list_has "$copyed_infs" "$inf"; then
                parse_inf_and_cp_driever "$inf" "$dst" "$arch" false
                copyed_infs=$(list_add "$copyed_infs" "$inf")
            fi
        done < <(find $src -type f -iname "*.inf" "$@")
    }

    # 
    add_drivers

    # win7  bootx64.efi  efi 
    if is_efi; then
        [ $arch = amd64 ] && boot_efi=bootx64.efi || boot_efi=bootaa64.efi

        local src dst
        dst=$(get_path_in_correct_case /os/boot/efi/EFI/boot/$boot_efi)
        if ! [ -f $dst ]; then
            mkdir -p "$(dirname $dst)"
            src=$(get_path_in_correct_case /wim/Windows/Boot/EFI/bootmgfw.efi)
            cp "$src" "$dst"
        fi
    fi

    # 
    #  windows-setup.bat  autounattend.xml 
    wim_autounattend_xml=$(get_path_in_correct_case /wim/autounattend.xml)
    wim_windows_xml=$(get_path_in_correct_case /wim/windows.xml)
    wim_setup_exe=$(get_path_in_correct_case /wim/setup.exe)

    xmlstarlet ed -d '//comment()' /tmp/autounattend.xml >$wim_autounattend_xml
    unix2dos $wim_autounattend_xml
    info "autounattend.xml"
    # 
    xmlstarlet ed -d '//*[name()="AdministratorPassword" or name()="Password"]' $wim_autounattend_xml | cat -n

    apk del xmlstarlet

    #  setup.exe 
    mv $wim_autounattend_xml $wim_windows_xml

    # 
    # https://slightlyovercomplicated.com/2016/11/07/windows-pe-startup-sequence-explained/
    # https://learn.microsoft.com/previous-versions/windows/it-pro/windows-vista/cc721977(v=ws.10)
    mv $wim_setup_exe $wim_setup_exe.disabled

    #  Windows/System32  winload.exe 
    # win7 win10  boot.wim  Windows/System32install.wim  Windows/System32
    # win2016     boot.wim  windows/system32install.wim  Windows/System32
    # wimmount 

    startnet_cmd=$(get_path_in_correct_case /wim/Windows/System32/startnet.cmd)
    winpeshl_ini=$(get_path_in_correct_case /wim/Windows/System32/winpeshl.ini)

    download $confhome/windows-setup.bat $startnet_cmd
    # dism 
    # sed -i "s|@image_name@|$image_name|" "$startnet.cmd"

    # shellcheck disable=SC2154
    if [ "$force_old_windows_setup" = 1 ]; then
        sed -i 's/ForceOldSetup=0/ForceOldSetup=1/i' $startnet_cmd
    fi

    #  SAC  EMS
    if $has_sac; then
        sed -i 's/EnableEMS=0/EnableEMS=1/i' $startnet_cmd
    fi

    # 4kn EFI  260M
    # https://learn.microsoft.com/windows-hardware/manufacture/desktop/hard-drives-and-partitions
    if is_4kn; then
        sed -i 's/is4kn=0/is4kn=1/i' $startnet_cmd
    fi

    # Windows Thin PC  Windows\System32\winpeshl.ini
    # [LaunchApps]
    # %SYSTEMDRIVE%\windows\system32\drvload.exe, %SYSTEMDRIVE%\windows\inf\sdbus.inf
    # %SYSTEMDRIVE%\setup.exe
    if [ -f "$winpeshl_ini" ]; then
        info "mod winpeshl.ini"
        # https://learn.microsoft.com/previous-versions/windows/it-pro/windows-vista/cc721977(v=ws.10)
        # 
        sed -i 's|setup.exe|windows\\system32\\cmd.exe, "/k %SYSTEMROOT%\\system32\\startnet.cmd"|i' "$winpeshl_ini"
        # sed -i 's|setup.exe|windows\\system32\\startnet.cmd|i' "$winpeshl_ini"
        cat -n "$winpeshl_ini"
    fi

    #  boot.wim
    info "Unmount boot.wim"
    wimunmount --commit /wim/

    # 
    # wimdelete /os/boot.wim 1
    # wimoptimize /os/boot.wim

    #  boot.wim 
    if is_nt_ver_ge 6.1; then
        # win7  boot.wim  1 
        #  win7 winre  install.wim Windows\System32\Recovery\winRE.wim
        images=$boot_index
    else
        # vista  boot.wim  1 
        # Windows cannot access the required file Drive:\Sources\Boot.wim.
        # Make sure all files required for installation are available and restart the installation.
        # Error code: 0x80070491
        # vista install.wim  Windows\System32\Recovery\winRE.wim
        images=all
    fi
    mkdir -p "$(get_path_in_correct_case "$(dirname $boot_dir/$sources_boot_wim)")"
    # 
    rm -f $boot_dir/$sources_boot_wim
    wimexport --boot /os/boot.wim "$images" $boot_dir/$sources_boot_wim
    info "boot.wim size"
    echo "Original:      $(get_filesize_mb /iso/$sources_boot_wim)"
    echo "Added Drivers: $(get_filesize_mb /os/boot.wim)"
    echo "Optimized:     $(get_filesize_mb "$boot_dir/$sources_boot_wim")"
    echo

    # vista  boot.wim
    if [ "$nt_ver" = 6.0 ] &&
        ! [ -e /os/installer/$sources_boot_wim ]; then
        cp $boot_dir/$sources_boot_wim /os/installer/$sources_boot_wim
    fi

    # windows 7  invoke-webrequest
    # installerD
    #  resize.bat  install.wim
    if true; then
        info "mount install.wim"
        wimmountrw $install_wim "$image_index" /wim/
        if false; then
            #  autounattend.xml
            # win7 
            download $confhome/windows-resize.bat /wim/windows-resize.bat
            for ethx in $(get_eths); do
                create_win_set_netconf_script /wim/windows-set-netconf-$ethx.bat
            done
        else
            modify_windows /wim
        fi

        info "Unmount install.wim"
        wimunmount --commit /wim/
    fi

    # 
    if is_efi; then
        #  add_default_efi_to_nvram()  bootx64.efi 
        # 
        if false; then
            apk add efibootmgr
            efibootmgr -c -L "Windows Installer" -d /dev/$xda -p1 -l "\\EFI\\boot\\$boot_efi"
        fi
    else
        #  ms-sys
        apk add grub-bios
        # efi  mbr  --target i386-pc
        grub-install --target i386-pc --boot-directory="$(get_path_in_correct_case /os/boot)" /dev/$xda
        cat <<EOF >"$(get_path_in_correct_case /os/boot/grub/grub.cfg)"
            set timeout=5
            menuentry "reinstall" {
                insmod search
                insmod ntldr
                search --no-floppy --label --set=root os
                ntldr /$(cd /os && get_path_in_correct_case bootmgr)
            }
EOF
    fi
}

#  netboot.efi 
download_netboot_xyz_efi() {
    dir=$1
    info "download netboot.xyz.efi"

    file=$dir/netboot.xyz.efi
    if [ "$(uname -m)" = aarch64 ]; then
        download https://boot.netboot.xyz/ipxe/netboot.xyz-arm64.efi $file
    else
        download https://boot.netboot.xyz/ipxe/netboot.xyz.efi $file
    fi
}

refind_main_disk() {
    if true; then
        apk add sfdisk
        main_disk=$(sfdisk --disk-id /dev/$xda | sed 's/0x//')
    else
        apk add lsblk
        # main_disk=$(blkid --match-tag PTUUID -o value /dev/$xda)
        main_disk=$(lsblk --nodeps -rno PTUUID /dev/$xda)
    fi
}

sync_time() {
    if false; then
        # armhttps
        # do 
        hwclock -s || true
    fi

    # ntp 
    # http 
    #       date header?
    method=http

    case "$method" in
    ntp)
        if is_in_china; then
            ntp_server=ntp.aliyun.com
        else
            ntp_server=pool.ntp.org
        fi
        # -d[d]   Verbose
        # -n      Run in foreground
        # -q      Quit after clock is set
        # -p      PEER
        ntpd -d -n -q -p "$ntp_server"
        ;;
    http)
        url="$(grep -m1 ^http /etc/apk/repositories)/$(uname -m)/APKINDEX.tar.gz"
        # 
        date_header=$(wget -S --no-check-certificate --spider "$url" 2>&1 | grep -m1 '^  Date:')
        # gnu date  -D
        busybox date -u -D "  Date: %a, %d %b %Y %H:%M:%S GMT" -s "$date_header"
        ;;
    esac

    #  alpine 
    # hwclock -w
}

is_ubuntu_lts() {
    IFS=. read -r major minor < <(echo "$releasever")
    [ $((major % 2)) = 0 ] && [ $minor = 04 ]
}

get_ubuntu_kernel_flavor() {
    # 20.04/22.04 kvm  vnc 
    # 24.04 kvm = virtual
    # linux-image-virtual = linux-image-6.x-generic
    # linux-image-generic = linux-image-6.x-generic + amd64-microcode + intel-microcode + linux-firmware + linux-modules-extra-generic

    # TODO: ISO virtual-hwe-24.04  linux-image-extra-virtual-hwe-24.04 

    # https://github.com/systemd/systemd/blob/main/src/basic/virt.c
    # https://github.com/canonical/cloud-init/blob/main/tools/ds-identify
    # http://git.annexia.org/?p=virt-what.git;a=blob;f=virt-what.in;hb=HEAD

    # 
    # $(get_cloud_vendor)  cache_dmi_and_virt
    #  $(get_cloud_vendor)  subshell 
    # subshell 
    #  cache_dmi_and_virt
    cache_dmi_and_virt
    vendor="$(get_cloud_vendor)"
    case "$vendor" in
    aws | gcp | oracle | azure | ibm) echo $vendor ;;
    *)
        is_ubuntu_lts && suffix=-hwe-$releasever || suffix=
        if is_virt; then
            echo virtual$suffix
        else
            echo generic$suffix
        fi
        ;;
    esac
}

install_redhat_ubuntu() {
    info "Download iso installer"

    #  grub2
    if is_efi; then
        # grubf38 arm
        # https://forums.fedoraforum.org/showthread.php?330104-aarch64-pxeboot-vmlinuz-file-format-changed-broke-PXE-installs
        apk add grub-efi efibootmgr
        grub-install --efi-directory=/os/boot/efi --boot-directory=/os/boot
    else
        apk add grub-bios
        grub-install --boot-directory=/os/boot /dev/$xda
    fi

    #  extragrub
    extra_cmdline=''
    for var in $(grep -o '\bextra_[^ ]*' /proc/cmdline | xargs); do
        if [[ "$var" = "extra_main_disk=*" ]]; then
            # 
            refind_main_disk
            extra_cmdline="$extra_cmdline extra_main_disk=$main_disk"
        else
            extra_cmdline="$extra_cmdline $(echo $var | sed -E "s/(extra_[^=]*)=(.*)/\1='\2'/")"
        fi
    done

    # 
    # https://anaconda-installer.readthedocs.io/en/latest/boot-options.html#console
    console_cmdline=$(get_ttys console=)
    grub_cfg=/os/boot/grub/grub.cfg

    # grublinux/linuxefi
    # shellcheck disable=SC2154
    if [ "$distro" = "ubuntu" ]; then
        download $iso /os/installer/ubuntu.iso
        mkdir -p /iso
        mount -o ro /os/installer/ubuntu.iso /iso

        # 
        kernel=$(get_ubuntu_kernel_flavor)

        # 
        # https://canonical-subiquity.readthedocs-hosted.com/en/latest/reference/autoinstall-reference.html#id
        # 20.04  minimal  install-sources.yaml
        source_id=
        if [ -f /iso/casper/install-sources.yaml ]; then
            ids=$(grep id: /iso/casper/install-sources.yaml | awk '{print $2}')
            if [ "$(echo "$ids" | wc -l)" = 1 ]; then
                source_id=$ids
            else
                [ "$minimal" = 1 ] && v= || v=-v
                source_id=$(echo "$ids" | grep $v '\-minimal')

                if [ "$(echo "$source_id" | wc -l)" -gt 1 ]; then
                    error_and_exit "find multi source id."
                fi
            fi
        fi

        #  ds="nocloud-net;s=https://xxx/" dsds
        # $seed  https://xxx/
        cat <<EOF >$grub_cfg
        set timeout=5
        menuentry "reinstall" {
            # https://bugs.launchpad.net/ubuntu/+source/grub2/+bug/1851311
            # rmmod tpm
            insmod all_video
            insmod search
            insmod loopback
            search --no-floppy --label --set=root installer
            loopback loop /ubuntu.iso
            linux (loop)/casper/vmlinuz iso-scan/filename=/ubuntu.iso autoinstall noprompt noeject cloud-config-url=$ks $extra_cmdline extra_kernel=$kernel extra_source_id=$source_id --- $console_cmdline
            initrd (loop)/casper/initrd
        }
EOF
    else
        download $vmlinuz /os/vmlinuz
        download $initrd /os/initrd.img
        download $squashfs /os/installer/install.img

        cat <<EOF >$grub_cfg
        set timeout=5
        menuentry "reinstall" {
            insmod all_video
            insmod search
            search --no-floppy --label --set=root os
            linux /vmlinuz inst.stage2=hd:LABEL=installer:/install.img inst.ks=$ks $extra_cmdline $console_cmdline
            initrd /initrd.img
        }
EOF
    fi

    cat "$grub_cfg"
}

trans() {
    info "start trans"

    mod_motd

    #  modloop 
    #  ext4  mount 
    # https://github.com/bin456789/reinstall/issues/136
    ensure_service_started modloop

    cat /proc/cmdline
    clear_previous
    add_community_repo

    # 
    #  xda
    # xda=sda ash trans.start
    if [ -z "$xda" ]; then
        find_xda
    fi

    if [ "$distro" != "alpine" ]; then
        setup_web_if_enough_ram
        # util-linux  lsblk
        # util-linux  mount 
        apk add util-linux
    fi

    # dd qemu 
    # shellcheck disable=SC2154
    if [ "$distro" = "dd" ] && [ "$img_type" = "qemu" ]; then
        #  reinstall.sh ?
        distro=any
        cloud_image=1
    fi

    if is_use_cloud_image; then
        case "$img_type" in
        qemu)
            create_part
            download_qcow
            case "$distro" in
            centos | almalinux | rocky | oracle | redhat | anolis | opencloudos | openeuler)
                # 8~9g xfs5g
                install_qcow_by_copy
                ;;
            ubuntu)
                # 24.04  boot  dd 
                install_qcow_by_copy
                ;;
            *)
                # debian fedora opensuse arch gentoo any
                dd_qcow
                resize_after_install_cloud_image
                modify_os_on_disk linux
                ;;
            esac
            ;;
        raw)
            #  raw 
            dd_raw_with_extract
            resize_after_install_cloud_image
            modify_os_on_disk linux
            ;;
        esac
    elif [ "$distro" = "dd" ]; then
        case "$img_type" in
        raw)
            dd_raw_with_extract
            if false; then
                # linux  xfs
                # windows  windows 
                resize_after_install_cloud_image
            fi
            if [ -d /configs/cloud-data ]; then
                modify_os_on_disk nocloud
            else
                modify_os_on_disk windows
            fi
            ;;
        qemu) # dd qemu 
            ;;
        esac
    else
        # 
        case "$distro" in
        alpine)
            install_alpine
            ;;
        arch | gentoo | aosc)
            create_part
            install_arch_gentoo_aosc
            ;;
        nixos)
            create_part
            install_nixos
            ;;
        fnos)
            create_part
            install_fnos
            ;;
        *)
            create_part
            mount_part_for_iso_installer
            case "$distro" in
            centos | almalinux | rocky | fedora | ubuntu | redhat) install_redhat_ubuntu ;;
            windows) install_windows ;;
            esac
            ;;
        esac
    fi

    #  lsblk efibootmgr  1M 
    #  alpine 
    if is_efi; then
        del_invalid_efi_entry
        add_default_efi_to_nvram
    fi

    info 'done'
    #  web 
    sleep 5
}

# 
# debian initrd  main
#  create_ifupdown_config 
: main

# 
# 
# 
# 
if ! [ "$(readlink -f "$0")" = /trans.sh ]; then
    cp -f "$0" /trans.sh
fi
trap 'trap_err $LINENO $?' ERR

# 
rm -f /etc/local.d/trans.start
rm -f /etc/runlevels/default/local

# 
extract_env_from_cmdline

# 
#  exec 
if [ "$1" = "update" ]; then
    info 'update script'
    # shellcheck disable=SC2154
    wget -O /trans.sh "$confhome/trans.sh"
    chmod +x /trans.sh
    exec /trans.sh
elif [ "$1" = "alpine" ]; then
    info 'switch to alpine'
    distro=alpine
    # 
    cloud_image=0
elif [ -n "$1" ]; then
    error_and_exit "unknown option $1"
fi

# 
#  ramdisk  50%
mount / -o remount,size=100%

# 
# 1.  https 
# 2.  https://github.com/bin456789/reinstall/issues/223
#    E: Release file for http://security.ubuntu.com/ubuntu/dists/noble-security/InRelease is not valid yet (invalid for another 5h 37min 18s).
#    Updates for this repository will not be applied.
# 3.  rtc windows rtc linux rtc  utc 
# 4. 
sync_time || true

#  ssh 
apk add openssh-server
if is_need_change_ssh_port; then
    change_ssh_port / $ssh_port
fi

#  +  ssh 
add_user_if_need /
if is_need_set_ssh_keys; then
    set_ssh_keys_and_del_password /
    change_ssh_conf_for_key_login /
    printf '\n' | setup-sshd
else
    change_user_password /
    change_ssh_conf_for_password_login /
    printf '\nyes' | setup-sshd
fi

#  frpc
# 
if ls /configs/frpc.* >/dev/null 2>&1 && ! pidof frpc >/dev/null; then
    info 'run frpc'
    add_community_repo
    apk add frp
    while true; do
        frpc -c /configs/frpc.* || true
        sleep 5
    done &
fi

# shellcheck disable=SC2154
if [ "$hold" = 1 ]; then
    if is_run_from_locald; then
        info "hold"
        exit
    fi
fi

# 
# shellcheck disable=SC2046,SC2194
case 1 in
1)
    # ChatGPT 
    exec > >(exec tee $(get_ttys /dev/) /reinstall.log) 2>&1
    trans
    ;;
2)
    exec > >(tee $(get_ttys /dev/) /reinstall.log) 2>&1
    trans
    ;;
3)
    trans 2>&1 | tee $(get_ttys /dev/) /reinstall.log
    ;;
esac

if [ "$hold" = 2 ]; then
    info "hold 2"
    exit
fi

# swapoff -a
# umount ?
sync
reboot
