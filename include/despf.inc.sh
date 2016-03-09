##############################################################################
#
# Copyright 2015 spf-tools team (see AUTHORS)
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
#     Unless required by applicable law or agreed to in writing, software
#     distributed under the License is distributed on an "AS IS" BASIS,
#     WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#     See the License for the specific language governing permissions and
#     limitations under the License.
#
##############################################################################

DNS_TIMEOUT=${DNS_TIMEOUT:-"2"}
TIMEOUT_CMD=${TIMEOUT_CMD:-$(which timeout)}

mdrill() {
  TYPE=${1}
  ${TIMEOUT_CMD:-"timeout"} $DNS_TIMEOUT drill "$@" \
      | sed -n "/^[^;]/{/$TYPE/p}" \
      || { echo "DNS lookup error!" >&2; cleanup; false; }
}

mdrills() {
  test $# -gt 1 && {
    TYPE=${1}
    TYPE=$(echo $TYPE | tr '[a-z]' '[A-Z]')
    shift
  }
  HOST=${1:-"spf-tools.ml"}
  shift

  mdrill $TYPE $HOST "$@" | sed -n "s/^$HOST.*IN\t$TYPE\t//p" \
    | grep .
}

# findns <domain>
# Find an authoritative NS server for domain
findns() {
  dd="$1"; ns=""; dig=${2:-"mdrills"}
  while test -z "$ns"
  do
    if
      ns=$($dig NS $dd | grep .)
    then
      break
    else
      echo $dd | grep -q '\.' && { dd="${dd#*.}"; unset ns; } || break
    fi
  done
  echo "$ns" | grep '^[^;]'
}

# printip <<EOF
# 1.2.3.4
# fec0::1
# EOF
# ip4:1.2.3.4
# ip6:fec0::1
printip() {
  if [ "x" != "x$1" ] ; then 
    prefix="/$1";
  fi
  while read line
  do
    if echo $line | grep -q ':'; then ver=6
    elif echo $line | grep -q '\.'; then ver=4
    else EXIT=1; break 1
    fi
    echo "ip${ver}:${line}${prefix}"
  done
  return $EXIT
}

# dea <hostname>
# dea both.spf-tools.ml
# 1.2.3.4
# fec0::1
dea() {
  if
    CNAME=$(mdrills CNAME $1 | grep .)
  then
    dea $CNAME $2
  else
    for TYPE in A AAAA; do mdrills $TYPE $1 | printip $2 || true; done
  fi
}

# demx <domain>
# Get MX record for a domain
demx() {
  mymx=$(mdrills MX $1 | awk '{print $2}' | grep -m1 .)
  for name in $mymx; do dea $name $2; done
}

# parsepf <host>
parsepf() {
  host=$1
  myns=$(findns $host 2>/dev/null)
  for ns in $myns
  do
    mdrills TXT $host @$ns 2>/dev/null | sed 's/^"//;s/"$//;s/" "//' \
      | grep -E '^v=spf1\s+' && break
  done
}

# getem <includes>
# e.g. includes="include:gnu.org include:google.com"
getem() {
  myloop=$1
  shift
  echo $* | tr " " "\n" | sed '/^$/d' | cut -b 9- | while read included
  do echo Getting $included 1>&2; despf $included $myloop
  done
}

# getamx <a:modifiers>
# e.g. a="a a:gnu.org a:google.com/24"
getamx() {
  host=$1
  local myloop=$2
  shift
  shift
  for record in $* ; do 
    local cidr=$(echo $record | cut -s -d\/ -f2-)
    local ahost=$(echo $record | cut -s -d: -f2-)
    if [ "x" = "x$ahost" ] ; then
      lookuphost="$host";
      mech=$(echo $record | cut -d/ -f1)
    else
      # try to catch "a/24", "a",  "a:host.tld/24" and "a:host.tld"
      mech=$(echo $record | cut -d: -f1 | cut -d/ -f1)
      if [ "x" = "x$cidr" ] ; then
        lookuphost=$ahost
      else
        lookuphost=$(echo $ahost | cut -d\/ -f1)
      fi
    fi
    if [ "$mech" = "a" ]; then
      dea $lookuphost $cidr
    elif [ "$mech" = "mx" ]; then
      demx $lookuphost $cidr
    fi
  done
}

# despf <domain>
despf() {
  host=$1
  myloop=$2

  # Detect loop
  echo $host | grep -qxFf $myloop && {
    #echo "Loop detected with $host!" 1>&2
    return
  }

  echo "$host" >> "${myloop}"
  myspf=$(parsepf $host | sed 's/redirect=/include:/')

  set +e
  dogetem=$(echo $myspf | grep -Eo 'include:\S+') \
    && getem $myloop $dogetem
  dogetamx=$(echo $myspf | grep -Eo -w '(mx|a)((\/|:)\S+)?')  \
    && getamx $host $myloop $dogetamx
  echo $myspf | grep -Eo 'ip[46]:\S+'
  set -e
}

cleanup() {
  myloop=$1
  test -n "$myloop" && rm ${myloop}*
}

despfit() {
  host=$1
  myloop=$2

  # Make sort(1) behave
  export LC_ALL=C
  export LANG=C

  despf $host $myloop > "$myloop-out"
  sort -u $myloop-out
}
