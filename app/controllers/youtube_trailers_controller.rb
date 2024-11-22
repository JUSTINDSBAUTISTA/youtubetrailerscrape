require "csv"
require "open-uri"
require "zip"
require "aws-sdk-s3"
require "time_difference"
class YoutubeTrailersController < ApplicationController
  @@progress = {
    current: 0,
    total: 0,
    successful: [],
    unsuccessful: [],
    invalid_links: []
  }
  @@current_log = ""
  @@zip_ready = false
  @@scraping_status = { stopped: false }

  # Reset scraping state and clear cache
  def reset
    clean_tmp_directory # Clears temporary files
    reset_progress # Resets in-memory progress variables
    clean_up_state_files # Removes any stop or pause state files

    Rails.logger.info("Reset complete. All temporary data cleared.")
    redirect_to youtube_trailers_path, notice: "Reset complete. All temporary data cleared."
  end

  # Deletes all files from the tmp directory
  def clean_tmp_directory
    tmp_path = Rails.root.join("tmp")
    Dir.foreach(tmp_path) do |file|
      file_path = File.join(tmp_path, file)
      # Skip directories like "." and ".."
      next if file == "." || file == ".."

      # Delete the file or directory
      if File.directory?(file_path)
        FileUtils.rm_rf(file_path) # Remove directories recursively
      else
        File.delete(file_path) if File.exist?(file_path) # Remove files
      end
    end
    Rails.logger.info("Temporary files deleted from #{tmp_path}.")
  end

  def fetch
    # Clean the tmp directory before starting
    clean_tmp_directory

    # Check if scraping has been stopped before processing
    unless check_scraping_status
      Rails.logger.info("Scraping stopped before processing started.")
      render json: { status: "stopped", message: "Scraping stopped by user." }, status: :ok
      return
    end

    uploaded_file = params[:file]
    file_path = uploaded_file.tempfile.path

    today_date = Date.today.strftime("%Y-%m-%d")
    @@progress[:total] = 0
    @@progress[:current] = 0

    csv_data = CSV.read(file_path, headers: true)

    # Check scraping status again after loading CSV
    unless check_scraping_status
      Rails.logger.info("Scraping stopped before processing CSV rows.")
      render json: { status: "stopped", message: "Scraping stopped by user." }, status: :ok
      return
    end

    @@progress[:total] = csv_data.size

    if csv_data.headers == %w[idTag YoutubeLink]
      handle_new_csv(csv_data, today_date)
    else
      render json: { error: "Invalid CSV format. Please upload a valid file." }, status: :unprocessable_entity
    end
  end

  # Download ZIP file
  def download_zip
    zip_name = params[:zip_name]
    if zip_name.blank?
      render plain: "ZIP name is missing", status: :bad_request
      return
    end

    begin
      s3_object = s3_client.bucket(ENV["AWS_BUCKET_NAME"]).object(zip_name)
      unless s3_object.exists?
        render plain: "The requested ZIP file does not exist on S3.", status: :not_found
        return
      end

      zip_data = s3_object.get.body.read

      # Send the ZIP file as a response
      send_data zip_data,
                filename: File.basename(zip_name),
                type: "application/zip",
                disposition: "attachment"
    rescue Aws::S3::Errors::NoSuchKey
      render plain: "The requested ZIP file does not exist on S3.", status: :not_found
    rescue StandardError => e
      render plain: "Error fetching ZIP file: #{e.message}", status: :internal_server_error
    end
  end

  # Retry failed uploads
  def retry_failed
    file_path = Rails.root.join("tmp", "updated_links.csv")
    return redirect_to youtube_trailers_path, alert: "No previous CSV found." unless File.exist?(file_path)

    csv_data = CSV.read(file_path, headers: true)
    failed_rows = csv_data.select { |row| row["failure"] == "1" }

    if failed_rows.empty?
      redirect_to youtube_trailers_path, notice: "All links are successfully scraped."
      return
    end

    today_date = Date.today.strftime("%Y-%m-%d")
    handle_updated_csv(failed_rows, today_date)
    redirect_to youtube_trailers_path, notice: "Retry completed. Check the updated CSV."
  end

  def progress
    zip_key = "#{Date.today.strftime('%Y-%m-%d')}-Batch/youtube_trailers_data.zip"
    bucket = s3_client.bucket(ENV["AWS_BUCKET_NAME"])
    zip_object = bucket.object(zip_key)

    # Check ZIP ready status
    @@zip_ready = zip_object.exists? && zip_object.content_length.positive?

    Rails.logger.info("Checking for ZIP file in S3: #{zip_key}")
    Rails.logger.info("ZIP ready status: #{@@zip_ready}")

    # Time tracking variables
    start_time = @@progress[:start_time] ||= Time.now # Set to now if not initialized
    current_time = Time.now
    elapsed_seconds = (current_time - start_time).to_i
    completed_items = @@progress[:current] || 0
    total_items = @@progress[:total] || 1

    # Calculate remaining time
    remaining_time = { hours: 0, minutes: 0, seconds: 0 }
    if completed_items > 0 && completed_items < total_items
      time_per_item = elapsed_seconds.to_f / completed_items
      remaining_seconds = (time_per_item * (total_items - completed_items)).to_i

      # Use `TimeDifference` to format remaining time
      remaining_time_obj = Time.now + remaining_seconds
      remaining_time = TimeDifference.between(current_time, remaining_time_obj).in_general
    end

    render json: {
      current: completed_items,
      successful_count: @@progress[:successful].size,
      unsuccessful_count: @@progress[:unsuccessful].size,
      invalid_links_count: @@progress[:invalid_links].size,
      successful_details: @@progress[:successful],
      unsuccessful_details: @@progress[:unsuccessful],
      invalid_details: @@progress[:invalid_links],
      current_log: @@current_log || "No logs yet.",
      total: total_items,
      elapsed_time: elapsed_seconds,
      remaining_time: {
        hours: remaining_time[:hours].to_i,
        minutes: remaining_time[:minutes].to_i,
        seconds: remaining_time[:seconds].to_i
      },
      zip_ready: @@zip_ready
    }
  end


  def stop_scraping
    File.write(Rails.root.join("tmp", "scraping_stopped"), "")
    @@current_log = "Scraping stopped by user."
    Rails.logger.info(@@current_log)

    render json: { status: "stopped", message: "Scraping has been stopped successfully." }
  end

  def scrape_youtube_data(youtube_link, id_tag, zip, today_date)
    # Validate the YouTube link format
    unless youtube_link =~ /\Ahttps:\/\/(www\.)?youtube\.com\/watch\?v=[\w\-]{11}\z/
      # Add invalid links to `invalid_links` and skip further processing
      @@progress[:invalid_links] << { idTag: id_tag, YoutubeLink: youtube_link }
      Rails.logger.info("Invalid links: #{@@progress[:invalid_links]}")
      @@current_log = "Invalid YouTube Link detected: #{youtube_link}"
      Rails.logger.error(@@current_log)
      return false
    end

    begin
      Rails.logger.info("Processing YouTube link: #{youtube_link}")

      # Track success status for individual steps
      title_success = fetch_youtube_data(youtube_link, "title", zip, "Video_Title/#{id_tag}-Title.txt", today_date)
      description_success = fetch_youtube_data(youtube_link, "description", zip, "Video_Description/#{id_tag}-Description.txt", today_date, true)
      thumbnail_success = fetch_youtube_data(youtube_link, "thumbnail", zip, "Thumbnail_Image/#{id_tag}-Image.jpg", today_date, true)
      video_success = fetch_youtube_video(youtube_link, zip, "Video/#{id_tag}-Video.mp4", today_date)

      # If all steps are successful, mark as successful
      if title_success && description_success && thumbnail_success && video_success
        @@progress[:successful] << { idTag: id_tag, YoutubeLink: youtube_link }
        Rails.logger.info("Successfully processed: #{youtube_link}")
      else
        # If any step fails, mark as unsuccessful
        @@progress[:unsuccessful] << { idTag: id_tag, YoutubeLink: youtube_link }
        Rails.logger.error("Processing failed for: #{youtube_link}")
      end

      true
    rescue StandardError => e
      # Record unsuccessful scrape details in case of exceptions
      @@progress[:unsuccessful] << { idTag: id_tag, YoutubeLink: youtube_link }
      Rails.logger.error("Error processing #{youtube_link}: #{e.message}")
      false
    end
  end



  private

  def reset_progress
    @@progress = {
      current: 0,
      total: 0,
      successful: [],
      unsuccessful: []
    }
    @@current_log = ""
  end

  def scraping_stopped?
    stopped = File.exist?(Rails.root.join("tmp", "scraping_stopped"))
    stopped
  end

  # Finalize scraping and clean up
  def finalize_scraping(zip, today_date)
    Rails.logger.info("Finalizing the ZIP file...")
    @@current_log = "Finalizing the ZIP file..."
    zip.close if zip.respond_to?(:close)

    Tempfile.create([ "youtube_trailers_sync", ".zip" ]) do |tempfile|
      tempfile.write(zip.read) if zip.respond_to?(:read)
      tempfile.rewind
      upload_zip_to_s3(tempfile, today_date)
    end

    reset_progress
    clean_up_state_files
  end

  def clean_up_state_files
    File.delete(Rails.root.join("tmp", "scraping_stopped")) if File.exist?(Rails.root.join("tmp", "scraping_stopped"))
  end

  def check_scraping_status
    if scraping_stopped?
      @@current_log = "Scraping stopped. Finalizing results..."
      Rails.logger.info(@@current_log)
      return false # Indicate that scraping should stop
    end
    true # Continue scraping if not stopped
  end

  def scraping_stopped?
    File.exist?(Rails.root.join("tmp", "scraping_stopped"))
  end

  def handle_new_csv(csv_data, today_date)
    Tempfile.create([ "youtube_trailers", ".zip" ]) do |tempfile|
      Zip::OutputStream.open(tempfile) do |zip|
        csv_data.each_with_index do |row, index|
          # Stop scraping if the status is stopped
          unless check_scraping_status
            finalize_scraping(zip, today_date) # Finalize results
            Rails.logger.info("Scraping stopped during CSV processing.")
            return # Exit the method after finalizing
          end

          youtube_link = row["YoutubeLink"]
          id_tag = row["idTag"]

          scrape_youtube_data(youtube_link, id_tag, zip, today_date)
          @@progress[:current] = index + 1
        end
      end

      # Finalize ZIP file after successful scraping
      tempfile.rewind
      upload_zip_to_s3(tempfile, today_date)
    end
  end

  def fetch_youtube_data(link, data_type, zip, s3_key, today_date, is_file = false)
    # Include the date prefix in the S3 key
    full_s3_key = "#{today_date}-Batch/#{s3_key}"

    # Check if scraping should stop
    unless check_scraping_status
      @@current_log = "Scraping stopped while processing #{data_type} for #{link}."
      Rails.logger.info(@@current_log)
      return false
    end

    # Check if the file already exists on S3
    if s3_file_exists?(full_s3_key)
      @@current_log = "Skipping #{data_type} for #{link}: File already exists on S3."
      Rails.logger.info(@@current_log)
      return true
    end

    # Prepare output file path
    output_file = Rails.root.join("tmp", "#{data_type}-#{SecureRandom.uuid}")

    # Command mapping for yt-dlp
    command_map = {
      "title" => "--print 'title'",
      "description" => "--write-description --skip-download -o '#{output_file}.description'",
      "thumbnail" => "--write-thumbnail --skip-download -o '#{output_file}.%(ext)s'"
    }
    command = "yt-dlp --proxy '' #{command_map[data_type]} '#{link}'"

    @@current_log = "Fetching #{data_type} for #{link}..."
    Rails.logger.info(@@current_log)

    result = `#{command}`

    # Check again after command execution for stop status
    unless check_scraping_status
      @@current_log = "Scraping stopped after processing #{data_type} for #{link}."
      Rails.logger.info(@@current_log)
      return false
    end

    if data_type == "title"
      return if result.strip.empty?

      folder_name = Rails.root.join("tmp", File.dirname(s3_key))
      FileUtils.mkdir_p(folder_name)

      local_file_path = folder_name.join(File.basename(s3_key))
      File.write(local_file_path, result.strip)

      data = File.read(local_file_path)
      zip.put_next_entry(s3_key)
      zip.write(data)
      upload_to_s3(full_s3_key, local_file_path)

      File.delete(local_file_path)
    elsif is_file
      system(command)

      # Find the generated file
      file_path = Dir.glob("#{output_file}*").find { |f| File.exist?(f) }
      unless file_path
        @@current_log = "File not found for #{data_type}."
        Rails.logger.error(@@current_log)
        return false
      end

      folder_name = Rails.root.join("tmp", File.dirname(s3_key))
      FileUtils.mkdir_p(folder_name)

      local_file_path = folder_name.join(File.basename(s3_key))
      FileUtils.mv(file_path, local_file_path)

      data = File.read(local_file_path)
      zip.put_next_entry(s3_key)
      zip.write(data)
      upload_to_s3(full_s3_key, local_file_path)

      File.delete(local_file_path)
    else
      return if result.strip.empty?

      zip.put_next_entry(s3_key)
      zip.write(result.strip)
      upload_to_s3(full_s3_key, result.strip)
    end

    true
  rescue StandardError => e
    @@current_log = "Error processing #{data_type} for #{link}: #{e.message}"
    Rails.logger.error(@@current_log)
    false
  end

  def fetch_youtube_video(link, zip, s3_key, today_date)
    # Include the date prefix in the S3 key
    full_s3_key = "#{today_date}-Batch/#{s3_key}"

    unless check_scraping_status
      @@current_log = "Scraping stopped while downloading video for #{link}."
      Rails.logger.info(@@current_log)
      return false
    end

    # Check if the video already exists on S3
    if s3_file_exists?(full_s3_key)
      @@current_log = "Skipping video for #{link}: File already exists on S3."
      Rails.logger.info(@@current_log)
      return true
    end

    # Prepare paths and folders
    folder_name = File.dirname(s3_key)
    local_temp_path = Rails.root.join("tmp", folder_name)
    FileUtils.mkdir_p(local_temp_path)

    temp_video_path = local_temp_path.join(File.basename(s3_key))
    video_command = "yt-dlp --proxy '' -f 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]' -o '#{temp_video_path}' '#{link}'"

    @@current_log = "Downloading video for #{link}..."
    Rails.logger.info(@@current_log)

    # Execute the download command
    `#{video_command}`

    if $? != 0
      @@current_log = "Error downloading video: #{link}: Command failed with status #{$?.exitstatus}"
      Rails.logger.error(@@current_log)
      return false
    end

    # Check again after command execution for stop status
    unless check_scraping_status
      @@current_log = "Scraping stopped after downloading video for #{link}."
      Rails.logger.info(@@current_log)
      File.delete(temp_video_path) if File.exist?(temp_video_path)
      return false
    end

    # Validate the downloaded file
    unless File.exist?(temp_video_path)
      @@current_log = "[error] Failed to download video for #{link}. File does not exist."
      Rails.logger.error(@@current_log)
      return false
    end

    # Add to ZIP and upload to S3
    data = File.read(temp_video_path)
    zip.put_next_entry(s3_key)
    zip.write(data)
    upload_to_s3(full_s3_key, temp_video_path)

    # Clean up local file
    File.delete(temp_video_path)

    @@current_log = "[info] Video successfully downloaded and uploaded for #{link}."
    Rails.logger.info(@@current_log)
    true
  rescue StandardError => e
    @@current_log = "Error downloading video for #{link}: #{e.message}"
    Rails.logger.error(@@current_log)
    false
  end

  def s3_file_exists?(key)
    s3_client.bucket(ENV["AWS_BUCKET_NAME"]).object(key).exists?
  end

  # Upload ZIP to S3
  def upload_zip_to_s3(zip_file, today_date)
    zip_key = "#{today_date}-Batch/youtube_trailers_data.zip"
    s3_client.bucket(ENV["AWS_BUCKET_NAME"]).object(zip_key).put(body: zip_file.read)
    Rails.logger.info("ZIP file uploaded to S3: #{zip_key}")
  end

  # Upload data to S3
  def upload_zip_to_s3(zip_file, today_date)
    zip_key = "#{today_date}-Batch/youtube_trailers_data.zip"

    # Fetch current S3 folder contents
    bucket = s3_client.bucket(ENV["AWS_BUCKET_NAME"])
    s3_objects = bucket.objects(prefix: "#{today_date}-Batch/").collect(&:key)

    # Create a new ZIP file to ensure it syncs with the S3 folder
    Tempfile.create([ "youtube_trailers_sync", ".zip" ]) do |tempfile|
      Zip::OutputStream.open(tempfile) do |zip|
        s3_objects.each do |key|
          next if key == zip_key # Skip the existing ZIP file itself

          # Download the file from S3
          obj = bucket.object(key)
          file_data = obj.get.body.read

          # Add the file to the ZIP archive
          zip.put_next_entry(key.sub("#{today_date}-Batch/", "")) # Remove the prefix for folder structure in ZIP
          zip.write(file_data)
        end
      end

      tempfile.rewind

      # Upload the rebuilt ZIP file
      bucket.object(zip_key).put(body: tempfile.read)
      @@zip_ready = true
      Rails.logger.info("ZIP file updated and uploaded to S3: #{zip_key}")
    end
  end

  def upload_to_s3(key, file_path)
    obj = s3_client.bucket(ENV["AWS_BUCKET_NAME"]).object(key)
    obj.upload_file(file_path.to_s)
    Rails.logger.info("Uploaded to S3: #{key}")
  end

  # S3 Client Configuration
  def s3_client
    @s3_client ||= Aws::S3::Resource.new(
      region: ENV["AWS_REGION"],
      credentials: Aws::Credentials.new(
        ENV["AWS_ACCESS_KEY_ID"],
        ENV["AWS_SECRET_ACCESS_KEY"]
      )
    )
  end
end
