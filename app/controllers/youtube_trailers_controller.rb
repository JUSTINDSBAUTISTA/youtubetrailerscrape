require "csv"
require "open-uri"
require "zip"
require "aws-sdk-s3"

class YoutubeTrailersController < ApplicationController
  @@progress = {
    current: 0,
    total: 0,
    successful: [],
    unsuccessful: []
  }
  @@current_log = ""
  @@scraping_status = { paused: false, stopped: false }

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
        File.delete(file_path) # Remove regular files
      end
    end
    Rails.logger.info("Temporary files deleted from #{tmp_path}.")
  end

  def fetch
    # Clean the tmp directory before starting
    clean_tmp_directory

    uploaded_file = params[:file]
    file_path = uploaded_file.tempfile.path

    today_date = Date.today.strftime("%Y-%m-%d")
    @@progress[:total] = 0
    @@progress[:current] = 0

    csv_data = CSV.read(file_path, headers: true)
    @@progress[:total] = csv_data.size

    if csv_data.headers == %w[idTag YoutubeLink]
      handle_new_csv(csv_data, today_date)
    else
      render json: { error: "Invalid CSV format. Please upload a valid file." }, status: :unprocessable_entity
      nil
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

  # Display progress
  def progress
    zip_key = "#{Date.today.strftime('%Y-%m-%d')}-Batch/youtube_trailers_data.zip"
    bucket = s3_client.bucket(ENV["AWS_BUCKET_NAME"])
    zip_object = bucket.object(zip_key)

    zip_ready = false
    if zip_object.exists?
      # Check if the Content-Length is greater than zero
      zip_ready = zip_object.content_length.positive?
    end

    Rails.logger.info("Checking for ZIP file in S3: #{zip_key}")
    Rails.logger.info("ZIP ready status: #{zip_ready}")

    render json: {
      current: @@progress[:current] || 0,
      successful_count: @@progress[:successful].size,
      unsuccessful_count: @@progress[:unsuccessful].size,
      successful_details: @@progress[:successful],
      unsuccessful_details: @@progress[:unsuccessful],
      current_log: @@current_log || "No logs yet.",
      total: @@progress[:total] || 1,
      zip_ready: zip_ready
    }
  end

  def pause_scraping
    File.write(Rails.root.join("tmp", "scraping_paused"), "")
    @@current_log = "Scraping paused by user."
    Rails.logger.info(@@current_log)
    render json: { status: "paused" }
  end

  def resume_scraping
    paused_file = Rails.root.join("tmp", "scraping_paused")
    File.delete(paused_file) if File.exist?(paused_file)
    @@current_log = "Scraping resumed by user."
    Rails.logger.info(@@current_log)
    render json: { status: "resumed" }
  end

  def stop_scraping
    File.write(Rails.root.join("tmp", "scraping_stopped"), "")
    @@current_log = "Scraping stopped by user."
    Rails.logger.info(@@current_log)
    render json: { status: "stopped" }
  end

  def scrape_youtube_data(youtube_link, id_tag, zip, today_date)
    return false unless youtube_link =~ /\Ahttps:\/\/(www\.)?youtube\.com\/watch\?v=.+/

    begin
      # Check pause/stop before starting
      unless check_scraping_status
        finalize_scraping(zip, today_date)
        return false
      end

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

  # Check if scraping is paused
  def scraping_paused?
    paused = File.exist?(Rails.root.join("tmp", "scraping_paused"))
    paused
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

    clean_up_state_files
  end

  def clean_up_state_files
    File.delete(Rails.root.join("tmp", "scraping_paused")) if File.exist?(Rails.root.join("tmp", "scraping_paused"))
    File.delete(Rails.root.join("tmp", "scraping_stopped")) if File.exist?(Rails.root.join("tmp", "scraping_stopped"))
  end

  def check_scraping_status
    loop do
      if scraping_stopped?
        @@current_log = "Scraping stopped. Finalizing the ZIP file..."
        Rails.logger.debug("check_scraping_status: Scraping stopped detected.")
        Rails.logger.info(@@current_log)
        return false # Stop processing
      end

      if scraping_paused?
        @@current_log = "Scraping paused. Waiting to resume..."
        Rails.logger.debug("check_scraping_status: Scraping paused detected.")
        Rails.logger.info(@@current_log)

        # Wait until resumed
        sleep(1) while scraping_paused?
        @@current_log = "Scraping resumed."
        Rails.logger.info(@@current_log)
      else
        break # Continue processing when neither paused nor stopped
      end
    end

    true # Indicate the process should continue
  end

  def handle_new_csv(csv_data, today_date)
    Tempfile.create([ "youtube_trailers", ".zip" ]) do |tempfile|
      Zip::OutputStream.open(tempfile) do |zip|
        csv_data.each_with_index do |row, index|
          # Check pause/stop before processing
          unless check_scraping_status
            finalize_scraping(zip, today_date)
            return # Exit the method after finalizing
          end

          youtube_link = row["YoutubeLink"]
          id_tag = row["idTag"]

          scrape_youtube_data(youtube_link, id_tag, zip, today_date)
          @@progress[:current] = index + 1
        end
      end

      tempfile.rewind
      upload_zip_to_s3(tempfile, today_date)
    end
  end

  def fetch_youtube_data(link, data_type, zip, s3_key, today_date, is_file = false)
    # Include the date prefix in the S3 key
    full_s3_key = "#{today_date}-Batch/#{s3_key}"

    # Check if the file already exists on S3
    if s3_file_exists?(full_s3_key)
      @@current_log = "Skipping #{data_type} for #{link}: File already exists on S3."
      Rails.logger.info(@@current_log)
      return
    end

    # Rest of the method remains the same
    output_file = Rails.root.join("tmp", "#{data_type}-#{SecureRandom.uuid}")

    command_map = {
      "title" => "--print 'title'",
      "description" => "--write-description --skip-download -o '#{output_file}.description'",
      "thumbnail" => "--write-thumbnail --skip-download -o '#{output_file}.%(ext)s'"
    }
    command = "yt-dlp --proxy '' #{command_map[data_type]} '#{link}'"

    @@current_log = "Fetching #{data_type} for #{link}..."
    Rails.logger.info(@@current_log)

    result = `#{command}`

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

      file_path = Dir.glob("#{output_file}*").find { |f| File.exist?(f) }
      unless file_path
        @@current_log = "File not found for #{data_type}."
        Rails.logger.error(@@current_log)
        return
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
  rescue StandardError => e
    @@current_log = "Error processing #{data_type} for #{link}: #{e.message}"
    Rails.logger.error(@@current_log)
  end

  def fetch_youtube_video(link, zip, s3_key, today_date)
    # Include the date prefix in the S3 key
    full_s3_key = "#{today_date}-Batch/#{s3_key}"

    # Check if the video already exists on S3
    if s3_file_exists?(full_s3_key)
      @@current_log = "Skipping video for #{link}: File already exists on S3."
      Rails.logger.info(@@current_log)
      return
    end

    folder_name = File.dirname(s3_key)
    local_temp_path = Rails.root.join("tmp", folder_name)
    FileUtils.mkdir_p(local_temp_path)

    temp_video_path = local_temp_path.join(File.basename(s3_key))
    video_command = "yt-dlp --proxy '' -f 'bestvideo[ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4]' -o '#{temp_video_path}' '#{link}'"

    @@current_log = "Downloading video for #{link}..."
    Rails.logger.info(@@current_log)

    # Execute the command
    `#{video_command}`

    if File.exist?(temp_video_path)
      @@current_log = "[info] Video successfully downloaded for #{link}."
    else
      @@current_log = "[error] Failed to download video for #{link}."
    end

    return unless File.exist?(temp_video_path)

    data = File.read(temp_video_path)
    zip.put_next_entry(s3_key)
    zip.write(data)
    upload_to_s3(full_s3_key, temp_video_path)

    File.delete(temp_video_path)
  rescue StandardError => e
    @@current_log = "Error downloading video for #{link}: #{e.message}"
    Rails.logger.error(@@current_log)
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
