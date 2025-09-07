#!/bin/sh
#
# RPM creation script for ServiceNow syseng internal packages (general)

### CONFIGURABLE PARAMETERS

PKGNAME=qpress
SOURCEFILES="qpress"
EXCLUDEFILES=""

### END CONFIGURABLE PARAMETERS

# static vars
TOPDIR=/var/tmp/rpmtemp.$$
SPECFILE=${PKGNAME}.spec
SRC=${PKGNAME}.tar.gz

# stage build environment
mkdir -p ${TOPDIR}/{BUILD,SOURCES,RPMS/{noarch,x86_64},SRPMS,SPECS}
cp -f ${SPECFILE} ${TOPDIR}/SPECS/
mkdir -p _pkg/${PKGNAME}
cp -af ${SOURCEFILES} _pkg/${PKGNAME}/
PREV=$(pwd)

# remove unwanted files
cd _pkg/${PKGNAME}
for e in ${EXCLUDEFILES}; do
    find . -name "${e}" | xargs rm -rf
done;
cd ${PREV}

# create source tarball
(cd _pkg; tar -czf ${TOPDIR}/SOURCES/${SRC} ${PKGNAME})

# run the RPM build
cd ${TOPDIR}/SPECS/
rpmbuild --define="_topdir ${TOPDIR}" -ba ${SPECFILE}

# return to original path
cd ${PREV}

# gather results of the build
rm -rf _results
mkdir -p _results
for i in $(find ${TOPDIR}/ -name "*.rpm"); do
    cp -f $i _results/
done;

# clean up
rm -rf _pkg
rm -rf ${TOPDIR}