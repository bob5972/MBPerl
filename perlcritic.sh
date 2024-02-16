#!/bin/bash

for i in ./* ; do
    file $i | grep Perl &>/dev/null;
    if [ $? == 0 ]; then
        echo $i;
        perlcritic --profile ./perlcriticrc $i || exit 1
    fi;
done;
