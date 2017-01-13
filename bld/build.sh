#!/bin/bash
# Copyright (c) Microsoft. All rights reserved.
# Licensed under the MIT license. See LICENSE file in the project root for full license information.

set -e

build_clean=
build_root=$(cd "$(dirname "$0")/.." && pwd)
log_dir=$build_root
skip_unittests=OFF
use_zlog=OFF

cd "$build_root"
usage ()
{
    echo "build.sh [options]"
    echo "options"
    echo " -x,  --xtrace                 print a trace of each command"
    echo " -c,  --clean                  remove artifacts from previous build before building"
    echo " -cl, --compileoption <value>  specify a compile option to be passed to gcc"
    echo "   Example: -cl -O1 -cl ..."
    echo " --use-zlog                    compile in zlog as logging framework"
    echo " --skip-unittests              skip the running of unit tests (unit tests are run by default)"
    exit 1
}

process_args ()
{
    build_clean=0
    save_next_arg=0
    extracloptions=" "

    for arg in $*
    do
      if [ $save_next_arg == 1 ]
      then
        # save arg to pass to gcc
        extracloptions="$extracloptions $arg"
        save_next_arg=0
      else
          case "$arg" in
              "-x" | "--xtrace" ) set -x;;
              "-c" | "--clean" ) build_clean=1;;
              "-cl" | "--compileoption" ) save_next_arg=1;;
              "--use-zlog" ) use_zlog=ON;;
              "--skip-unittests" ) skip_unittests=ON;;
              * ) usage;;
          esac
      fi
    done
}

process_args $*

cmake_root="$build_root"/build
rm -r -f "$cmake_root"
mkdir -p "$cmake_root"
pushd "$cmake_root"
cmake -DCMAKE_BUILD_TYPE=Debug \
      -Dskip_unittests:BOOL=$skip_unittests \
      -Duse_zlog:BOOL=$use_zlog \
      "$build_root"

CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || sysctl -n hw.ncpu)

# Make sure there is enough virtual memory on the device to handle more than one job.
# We arbitrarily decide that 500 MB per core is what we need in order to run the build
# in parallel.
MINVSPACE=$(expr 500000 \* $CORES)

# Acquire total memory and total swap space setting them to zero in the event the command fails
MEMAR=( $(sed -n -e 's/^MemTotal:[^0-9]*\([0-9][0-9]*\).*/\1/p' -e 's/^SwapTotal:[^0-9]*\([0-9][0-9]*\).*/\1/p' /proc/meminfo) )
[ -z "${MEMAR[0]##*[!0-9]*}" ] && MEMAR[0]=0
[ -z "${MEMAR[1]##*[!0-9]*}" ] && MEMAR[1]=0

let VSPACE=${MEMAR[0]}+${MEMAR[1]}

if [ "$VSPACE" -lt "$MINVSPACE" ] ; then
  # We think the number of cores to use is a function of available memory divided by 500 MB
  CORES2=$(expr ${MEMAR[0]} / 500000)

  # Clamp the cores to use to be between 1 and $CORES (inclusive)
  CORES2=$([ $CORES2 -le 0 ] && echo 1 || echo $CORES2)
  CORES=$([ $CORES -le $CORES2 ] && echo $CORES || echo $CORES2)
fi

make --jobs=$CORES

if [[ $run_valgrind == 1 ]] ;
then
    #use doctored (-DPURIFY no-asm) openssl
    export LD_LIBRARY_PATH=/usr/local/ssl/lib
    ctest -j $CORES --output-on-failure
    export LD_LIBRARY_PATH=
else
    ctest -j $CORES -C "Debug" --output-on-failure
fi

popd

[ $? -eq 0 ] || exit $?

