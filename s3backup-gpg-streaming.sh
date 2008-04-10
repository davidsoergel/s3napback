#!/bin/sh

# This script will backup a given directory to S3, without using any temp files, and encrypting the archive

echo "Starting Backup"
date

BACKUP_TYPE=$1
DIR_TO_BACKUP=$2
BUCKET_NAME=$3
GPG_RECIPIENT=$4
DIFF_FILE=$5


if [ "${DIR_TO_BACKUP}" == ""  -o "${BACKUP_TYPE}" == "" -o "${BUCKET_NAME}" == "" ]; then
  echo "Usage: s3backup.sh <type> <dir> <bucket> <recipient> <diff file>"
  echo "   <type> = Full or Differential backup.  FULL / DIFF / NORMAL"
  echo "   <dir> = The directory to backup"
  echo "   <bucket> = The bucket to backup to"
  echo "   <recipient> = The GPG recipient key id"
  echo "   <diff file> = The tar DIFF file to use."
  exit;
fi

if [ "${BACKUP_TYPE}" != "FULL" -a "${BACKUP_TYPE}" != "DIFF" -a "${BACKUP_TYPE}" != "NORMAL" ]; then
  echo " Invalid backup type [${BACKUP_TYPE}] Must be one of FULL or DIFF or NORMAL"
  exit;
fi

if [ "${BACKUP_TYPE}" == "FULL" -o "${BACKUP_TYPE}" = "DIFF" ]; then
  if [ "${DIFF_FILE}" == "" ]; then
    echo " Invalid diff file name "
    exit;
  fi
fi


# Here is what we are going to do
echo "--------------------"
echo "Backing up directory [${DIR_TO_BACKUP}]"
echo "Backup type is [${BACKUP_TYPE}]"
echo "Bucket Name is [${BUCKET_NAME}]"
echo "DIFF File = [${DIFF_FILE}]"
echo "--------------------"

# If it's a full backup, then delete the diff file 
if [ "${BACKUP_TYPE}" == "FULL" ]; then
  echo "Performing a full backup, so deleting diff file [${DIFF_FILE}]"
  echo "--------------------"
  rm -f ${DIFF_FILE}
fi


# Delete the old bucket, if it exists
echo "Deleting Old Bucket [${BUCKET_NAME}]"
java -jar js3tream.jar -v -K key.txt -d -b ${BUCKET_NAME}
echo "--------------------"


# Prep the TGZ command
if [ "${BACKUP_TYPE}" == "NORMAL" ]; then
  MAKE_TGZ="tar -C / -czp ${DIR_TO_BACKUP}"
else
  MAKE_TGZ="tar -g ${DIFF_FILE} -C / -czp ${DIR_TO_BACKUP}"
fi
echo "--------------------"

ENCRYPT="gpg -r \"${GPG_RECIPIENT}\" -e" 
SEND_TO_S3="java -Xmx128M -jar js3tream.jar --debug -z 25000000 -n -v -K key.txt -i -b ${BUCKET_NAME}"


# send to S3
echo "Sending to S3"
echo "${MAKE_TGZ} | ${ENCRYPT} | ${SEND_TO_S3}"

${MAKE_TGZ} | ${ENCRYPT} | ${SEND_TO_S3}
echo "--------------------"


# Create a backup copy of the original backup diff
if [ "${BACKUP_TYPE}" == "FULL" ]; then
  echo "Creating a copy of the first diff file [${DIFF_FILE}] to [${DIFF_FILE}.orig]"
  cp -f ${DIFF_FILE} ${DIFF_FILE}.orig
  echo "--------------------"

fi

echo "Backup Finished"
date
