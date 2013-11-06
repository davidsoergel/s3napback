package com.davidsoergel.s3napback;

import com.amazonaws.auth.AWSCredentials;
import com.amazonaws.services.s3.AmazonS3;
import com.amazonaws.services.s3.AmazonS3Client;
import com.amazonaws.services.s3.model.GetObjectRequest;
import com.amazonaws.services.s3.model.S3Object;
import com.amazonaws.services.s3.transfer.Download;
import com.amazonaws.services.s3.transfer.Transfer;
import com.amazonaws.services.s3.transfer.TransferManager;
import com.amazonaws.services.s3.transfer.internal.DownloadImpl;
import com.amazonaws.services.s3.transfer.internal.DownloadMonitor;
import com.amazonaws.services.s3.transfer.internal.ProgressListenerChain;
import com.amazonaws.services.s3.transfer.internal.TransferManagerUtils;
import com.amazonaws.services.s3.transfer.internal.TransferProgressImpl;
import com.amazonaws.services.s3.transfer.internal.TransferProgressUpdatingListener;
import com.amazonaws.services.s3.transfer.internal.TransferStateChangeListener;
import com.amazonaws.util.VersionInfoUtils;

import java.io.BufferedOutputStream;
import java.util.concurrent.Callable;
import java.util.concurrent.Future;
import java.util.concurrent.ThreadPoolExecutor;

/**
 * @author <a href="mailto:dev@davidsoergel.com">David Soergel</a>
 * @version $Id$
 */
public class StreamingTransferManager extends TransferManager
	{
	private static final String USER_AGENT = TransferManager.class.getName() + "/" + VersionInfoUtils.getVersion();

	public StreamingTransferManager( AWSCredentials credentials )
		{
		this(new AmazonS3Client(credentials));
		}

	public StreamingTransferManager( AmazonS3 s3 )
		{
		this(s3, TransferManagerUtils.createDefaultExecutorService());
		}
	private AmazonS3 s3;
	private ThreadPoolExecutor threadPool;

	public StreamingTransferManager( final AmazonS3 s3, final ThreadPoolExecutor threadPool )
		{
		super(s3, threadPool);
		this.s3 = s3;
		this.threadPool = threadPool;
		}

	public Download download( String bucket, String key, final BufferedOutputStream os )
		{
		return download(new GetObjectRequest(bucket, key), os);
		}

	public Download download( final GetObjectRequest getObjectRequest, final BufferedOutputStream os )
		{
		return download(getObjectRequest, os, null);
		}


	private Download download( final GetObjectRequest getObjectRequest, final BufferedOutputStream os, final TransferStateChangeListener stateListener )
		{

		appendUserAgent(getObjectRequest, USER_AGENT);

		String description = "Downloading from " + getObjectRequest.getBucketName() + "/" + getObjectRequest.getKey();

		// Add our own transfer progress listener
		TransferProgressImpl transferProgress = new TransferProgressImpl();
		ProgressListenerChain listenerChain =
				new ProgressListenerChain(new TransferProgressUpdatingListener(transferProgress), getObjectRequest.getProgressListener());
		getObjectRequest.setProgressListener(listenerChain);

		final S3Object s3Object = s3.getObject(getObjectRequest);
		final DownloadImpl download = new DownloadImpl(description, transferProgress, listenerChain, s3Object, stateListener);

		// null is returned when constraints aren't met
		if (s3Object == null)
			{
			download.setState(Transfer.TransferState.Canceled);
			download.setMonitor(new DownloadMonitor(download, null));
			return download;
			}

		long contentLength = s3Object.getObjectMetadata().getContentLength();
		if (getObjectRequest.getRange() != null && getObjectRequest.getRange().length == 2)
			{
			long startingByte = getObjectRequest.getRange()[0];
			long lastByte = getObjectRequest.getRange()[1];
			contentLength = lastByte - startingByte;
			}
		transferProgress.setTotalBytesToTransfer(contentLength);

		Future<?> future = threadPool.submit(new Callable<Object>()
		{
		//@Override
		public Object call() throws Exception
			{
			try
				{
				download.setState(Transfer.TransferState.InProgress);
				StreamingServiceUtils.downloadObjectToStream(s3Object, os);
				download.setState(Transfer.TransferState.Completed);
				return true;
				}
			catch (Exception e)
				{
				// Downloads aren't allowed to move from canceled to failed
				if (download.getState() != Transfer.TransferState.Canceled)
					{
					download.setState(Transfer.TransferState.Failed);
					}
				throw e;
				}
			}
		});
		download.setMonitor(new DownloadMonitor(download, future));

		return download;
		}
	}
