#!/bin/bash

for i in ./* ; do
    file $i | grep Perl &>/dev/null;
    if [ $? == 0 ]; then
        echo $i;
        perl -I ./ -c $i || exit 1
        perlcritic --profile ./perlcriticrc $i || exit 1
    fi;
done;
