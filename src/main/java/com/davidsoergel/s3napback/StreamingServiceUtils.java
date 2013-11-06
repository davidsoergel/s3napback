package com.davidsoergel.s3napback;

import com.amazonaws.AmazonClientException;
import com.amazonaws.services.s3.internal.ServiceUtils;
import com.amazonaws.services.s3.model.S3Object;
import com.amazonaws.util.BinaryUtils;
import com.amazonaws.util.Md5Utils;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;

import java.io.BufferedOutputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.util.Arrays;


/**
 * @author <a href="mailto:dev@davidsoergel.com">David Soergel</a>
 * @version $Id$
 */
public class StreamingServiceUtils
	{
	private static final Logger log = LoggerFactory.getLogger(StreamingServiceUtils.class);


// copied from com.amazonaws.services.s3.internal.ServiceUtils in order to modify

	/**
	 * Downloads an S3Object, as returned from {@link com.amazonaws.services.s3.AmazonS3Client#getObject(com.amazonaws.services.s3.model.GetObjectRequest)
	 * }, to
	 * the specified file.
	 *
	 * @param s3Object        The S3Object containing a reference to an InputStream containing the object's data.
	 * @param destinationFile The file to store the object's data in.
	 */
	public static void downloadObjectToStream( S3Object s3Object, BufferedOutputStream eventualOutputStream )
		{
/*
		// attempt to create the parent if it doesn't exist
		File parentDirectory = destinationFile.getParentFile();
		if (parentDirectory != null && !parentDirectory.exists())
			{
			parentDirectory.mkdirs();
			}
*/

		ByteArrayOutputStream byteOS = new ByteArrayOutputStream((int) s3Object.getObjectMetadata().getContentLength());
		OutputStream outputStream = null;
		try
			{
			// perf extra copying, left over from file outputstream version
			outputStream = new BufferedOutputStream(byteOS);
			byte[] buffer = new byte[1024 * 10];
			int bytesRead;
			while ((bytesRead = s3Object.getObjectContent().read(buffer)) > -1)
				{
				outputStream.write(buffer, 0, bytesRead);
				}
			}
		catch (IOException e)
			{
			try
				{
				s3Object.getObjectContent().abort();
				}
			catch (IOException abortException)
				{
				log.warn("Couldn't abort stream", e);
				}
			throw new AmazonClientException("Unable to store object contents to disk: " + e.getMessage(), e);
			}
		finally
			{
			try {outputStream.close();} catch (Exception e) {}
			try {s3Object.getObjectContent().close();} catch (Exception e) {}
			}

		try
			{
			// Multipart Uploads don't have an MD5 calculated on the service side
			if (ServiceUtils.isMultipartUploadETag(s3Object.getObjectMetadata().getETag()) == false)
				{
				byte[] clientSideHash = Md5Utils.computeMD5Hash(byteOS.toByteArray()); //new FileInputStream(destinationFile));
				byte[] serverSideHash = BinaryUtils.fromHex(s3Object.getObjectMetadata().getETag());

				if (!Arrays.equals(clientSideHash, serverSideHash))
					{
					throw new AmazonClientException("Unable to verify integrity of data download.  " +
					                                "Client calculated content hash didn't match hash calculated by Amazon S3.  " +
					                                "The data may be corrupt; please try again.");
					}
				}
			}
		catch (Exception e)
			{
			log.warn("Unable to calculate MD5 hash to validate download: " + e.getMessage(), e);
			}

		try
			{
			eventualOutputStream.write(byteOS.toByteArray());
			}
		catch (Exception e)
			{

			log.warn("Unable to write to output stream: " + e.getMessage(), e);
			}
		}
	}
