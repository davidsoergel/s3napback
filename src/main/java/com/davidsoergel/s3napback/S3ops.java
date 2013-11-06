package com.davidsoergel.s3napback;

import com.amazonaws.auth.AWSCredentials;
import com.amazonaws.auth.BasicAWSCredentials;
import com.amazonaws.services.s3.model.DeleteObjectsRequest;
import com.amazonaws.services.s3.model.DeleteObjectsResult;
import com.amazonaws.services.s3.model.ListObjectsRequest;
import com.amazonaws.services.s3.model.ObjectListing;
import com.amazonaws.services.s3.model.ObjectMetadata;
import com.amazonaws.services.s3.model.S3ObjectSummary;
import com.amazonaws.services.s3.transfer.Download;
import com.amazonaws.services.s3.transfer.TransferManager;
import com.amazonaws.services.s3.transfer.Upload;
import com.amazonaws.services.s3.transfer.model.UploadResult;
import com.amazonaws.util.StringUtils;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import sun.security.provider.MD5;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayInputStream;
import java.io.FileInputStream;
import java.io.FileNotFoundException;
import java.io.IOException;
import java.io.InputStream;
import java.util.ArrayList;
import java.util.Date;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.SortedMap;
import java.util.TreeMap;

/**
 * Provide command-line interface for S3 put/get/delete/list operations-- just enough to support s3napback needs, no more.
 *
 * @author <a href="mailto:dev@davidsoergel.com">David Soergel</a>
 * @version $Id$
 */
public class S3ops
	{
	private static final Logger logger = LoggerFactory.getLogger(S3ops.class);

	public static void main( String[] argv )
		{
		int chunkSize = 25000000; // default 25 MB

		// hacky positional arguments, whatever
		String keyfileName = argv[0];
		String command = argv[1];
		String bucket = argv[2];
		String filename = argv[3];

		if (argv.length > 4) { chunkSize = new Integer(argv[3]); }

		Properties props = new Properties();
		try
			{
			props.load(new FileInputStream(keyfileName));
			}
		catch (FileNotFoundException e)
			{
			logger.error("Error", e);
			}
		catch (IOException e)
			{
			logger.error("Error", e);
			}
		String accessKey = props.getProperty("key");
		String secretKey = props.getProperty("secret");


		AWSCredentials myCredentials = new BasicAWSCredentials(accessKey, secretKey);
		StreamingTransferManager tx = new StreamingTransferManager(myCredentials);

		try
			{
			if (command.equals("upload"))
				{
				upload(tx, bucket, filename, chunkSize);
				}
			else if (command.equals("download"))
				{
				download(tx, bucket, filename);
				}
			else if (command.equals("delete"))
				{
				delete(tx, bucket, filename);
				}
			else if (command.equals("list"))
				{
				list(tx, bucket);
				}
			else
				{
				logger.error("Unknown command: " + command);
				}
			}
		catch (InterruptedException e)
			{
			logger.error("Error", e);
			System.exit(1);
			}
		catch (IOException e)
			{
			logger.error("Error", e);
			System.exit(1);
			}
		tx.shutdownNow();
		}

	public static void delete( TransferManager tx, String bucket, String fileprefix ) throws InterruptedException
		{
		logger.info("Deleting " + fileprefix);

		List<DeleteObjectsRequest.KeyVersion> keys = new ArrayList<DeleteObjectsRequest.KeyVersion>();

		ObjectListing objectListing = tx.getAmazonS3Client().listObjects(new ListObjectsRequest().withBucketName(bucket).withPrefix(fileprefix));
		for (S3ObjectSummary objectSummary : objectListing.getObjectSummaries())
			{
			keys.add(new DeleteObjectsRequest.KeyVersion(objectSummary.getKey()));
			}

		DeleteObjectsRequest req = new DeleteObjectsRequest(bucket);
		req.setKeys(keys);
		DeleteObjectsResult result = tx.getAmazonS3Client().deleteObjects(req);
		}

	public static void upload( TransferManager tx, String bucket, String filename, int chunkSize ) throws InterruptedException, IOException
		{
		//throw new NotImplementedException();

		// break input stream into chunks

		// fully read each chunk into memory before sending, in order to know the size and the md5

		// ** prepare the next chunk while the last is sending; need to deal with multithreading properly
		// ** 4 concurrent streams?

		InputStream in = new BufferedInputStream(System.in);
		int chunkNum = 0;
		while (in.available() > 0)
			{
			byte[] buf = new byte[chunkSize];
			int bytesRead = in.read(buf);

			String md5 = new MD5(buf);

			// presume AWS does its own buffering, no need for BufferedInputStream (?)

			ObjectMetadata meta = new ObjectMetadata();
			meta.setContentLength(bytesRead);
			meta.setContentMD5(md5);

			Upload myUpload = tx.upload(bucket, filename + ":" + chunkNum, new ByteArrayInputStream(buf), meta);
			UploadResult result = myUpload.waitForUploadResult();

			while (myUpload.isDone() == false)
				{
				System.out.println("Transfer: " + myUpload.getDescription());
				System.out.println("  - State: " + myUpload.getState());
				System.out.println("  - Progress: " + myUpload.getProgress().getBytesTransfered());
				// Do work while we wait for our upload to complete...
				Thread.sleep(500);
				}
			}
		}

	public static void list( StreamingTransferManager tx, String bucket ) throws InterruptedException
		{

		//** sort by date
		SortedMap<String, SortedMap<String, S3ObjectSummary>> blocks = new TreeMap<String, SortedMap<String, S3ObjectSummary>>();

		ObjectListing current = tx.getAmazonS3Client().listObjects(new ListObjectsRequest().withBucketName(bucket));

		List<S3ObjectSummary> keyList = current.getObjectSummaries();
		ObjectListing next = tx.getAmazonS3Client().listNextBatchOfObjects(current);
		keyList.addAll(next.getObjectSummaries());

		while (next.isTruncated())
			{
			current = tx.getAmazonS3Client().listNextBatchOfObjects(next);
			keyList.addAll(current.getObjectSummaries());
			next = tx.getAmazonS3Client().listNextBatchOfObjects(current);
			}
		keyList.addAll(next.getObjectSummaries());


		for (S3ObjectSummary objectSummary : keyList)
			{
			String[] c = objectSummary.getKey().split(":");
			if (c.length != 2)
				{ logger.warn("ignoring malformed filename " + objectSummary.getKey()); }
			else
				{
				String filename = c[0];
				String chunknum = c[1];

				SortedMap<String, S3ObjectSummary> chunks = blocks.get(filename);
				if (chunks == null)
					{
					chunks = new TreeMap<String, S3ObjectSummary>();
					blocks.put(filename, chunks);
					}

				chunks.put(chunknum, objectSummary);
				}
			}

		// now the files and chunks are in the maps in order
		for (Map.Entry<String, SortedMap<String, S3ObjectSummary>> blockEntry : blocks.entrySet())
			{
			String filename = blockEntry.getKey();
			SortedMap<String, S3ObjectSummary> chunks = blockEntry.getValue();

			long totalsize = 0;
			Date lastModified = null;
			for (Map.Entry<String, S3ObjectSummary> entry : chunks.entrySet())
				{
				totalsize += entry.getValue().getSize();
				lastModified = entry.getValue().getLastModified();
				}
			String[] line = { bucket, filename, "" + chunks.keySet().size(), "" + totalsize, lastModified.toString() };

			System.err.println(StringUtils.join("\t", line));

			// 2008-04-10 04:07:50 - dev.davidsoergel.com.backup1:MySQL/all-0 - 153.38k in 1 data blocks
			}
		}
	// ** download todo: use a TarInputStream, choose files.  Any hope of random access to needed chunks?  Ooh, maybe so,
	// just using the tar index and a random-access file facade!

	//** todo: download tar indexes only for all archives, list dates on which a given file is available

	public static void download( StreamingTransferManager tx, String bucket, String fileprefix ) throws InterruptedException, IOException
		{
		// first list the files

		SortedMap<String, S3ObjectSummary> chunks = new TreeMap<String, S3ObjectSummary>();

		ObjectListing objectListing = tx.getAmazonS3Client().listObjects(new ListObjectsRequest().withBucketName(bucket).withPrefix(fileprefix));
		for (S3ObjectSummary objectSummary : objectListing.getObjectSummaries())
			{
			chunks.put(objectSummary.getKey(), objectSummary);
			}


		logger.info("Downloading " + fileprefix);
		Date start = new Date();
		// now the chunks are in the map in order
		long totalBytes = 0;
		BufferedOutputStream out = new BufferedOutputStream(System.out);
		for (Map.Entry<String, S3ObjectSummary> entry : chunks.entrySet())
			{
			String key = entry.getKey();
			logger.info("Downloading " + key);

			Download myDownload = tx.download(bucket, key, out);
			while (myDownload.isDone() == false)
				{
				long bytes = totalBytes + myDownload.getProgress().getBytesTransfered();
				Double mb = (double) bytes / 1024. / 1024.;
				Double sec = (new Date().getTime() - start.getTime()) / 1000.;
				Double rate = mb / sec;

				logger.info(String.format("%.2f MB, %.2fMB/s", mb, rate));
				// Do work while we wait for our upload to complete...
				Thread.sleep(500);
				}
			totalBytes += myDownload.getProgress().getBytesTransfered();
			}
		out.close();


		Long bytes = totalBytes;
		Double mb = (double) bytes / 1024. / 1024.;
		Double sec = (new Date().getTime() - start.getTime()) / 1000.;
		Double rate = mb / sec;

		logger.info(String.format("Downloaded %s to stdout, %d bytes, %.2f sec, %.2fMB/s", fileprefix, totalBytes, sec, rate));
		//logger.info("Downloaded " + fileprefix + " to stdout, " + totalBytes + " bytes, " + sec +" sec, " + rate + " MB/sec");
		}
	}
