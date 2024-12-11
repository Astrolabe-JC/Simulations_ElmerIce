#!/bin/bash
# WARNING : this script only allows run witch begins in the 01/01 

# number of elmer partition + xios server (48 + 1 in this case)
NELMER=48
NXIOS=1
NP=$((NELMER+NXIOS))

# number of HPC nodes
NN=1

# first iteration number (if more than 1, means restart i-1 are already in place)
# end iteration
STARTITER=9
ENDITER=9

# define length of each segments
WALLTIME=25000
NSTEP=876
TIME_STP=2.5 # in days

# first year in atmospheric forcing file / first year to read in the simulation 
START_YEAR_FORCING=2015    
START_SIMU=2015
OFFSET=$((START_SIMU-START_YEAR_FORCING))

# first year in oceanic forcing file / first year to read in the simulation
START_YEAR_FORCING_OC=2015
OFFSETOC=$((START_SIMU-START_YEAR_FORCING_OC))

calc() { awk "BEGIN{print $*}"; }
TIME_RST=`calc $NSTEP*$TIME_STP` # in days

# restart path and rst file (assume all in $IELMER)
RSTINITpath=${IELMER}/RST_simplified2/
RSTINITfile=ISMIP6_W1-HistAE_002.restart.nc

# MSH path and file
MSHINITpath=${IELMER}/MSH_simplified2/
