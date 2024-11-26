require "csv"
require "open-uri"
require "aws-sdk-s3"
require "time_difference"
class YoutubeTrailersController < ApplicationController
  protect_from_forgery with: :exception

  @@progress = {
    current: 0,
    total: 0,
    successful: [],
    unsuccessful: [],
    invalid_links: []
  }
  @@current_log = ""
  @@scraping_status = { stopped: false }

  def progress
    puts "Here progress...."
    begin
      # Normal progress response
      start_time = @@progress[:start_time] ||= Time.now
      elapsed_seconds = (Time.now - start_time).to_i
      completed_items = @@progress[:current] || 0
      total_items = @@progress[:total] || 1

      # Calculate remaining time
      remaining_time = { hours: 0, minutes: 0, seconds: 0 }
      if completed_items.positive? && completed_items < total_items
        time_per_item = elapsed_seconds.to_f / completed_items
        remaining_seconds = (time_per_item * (total_items - completed_items)).to_i
        remaining_time = {
          hours: remaining_seconds / 3600,
          minutes: (remaining_seconds % 3600) / 60,
          seconds: remaining_seconds % 60
        }
      end

      render json: {
        current: completed_items,
        total: total_items,
        successful_count: @@progress[:successful].size,
        unsuccessful_count: @@progress[:unsuccessful].size,
        invalid_links_count: @@progress[:invalid_links].size,
        successful_details: @@progress[:successful],
        unsuccessful_details: @@progress[:unsuccessful],
        invalid_details: @@progress[:invalid_links],
        current_log: @@current_log || "No logs yet.",
        elapsed_time: elapsed_seconds,
        remaining_time: remaining_time
      }
    rescue StandardError => e
      Rails.logger.error("Unexpected error in progress: #{e.message}")
      render json: {
        error: "An unexpected error occurred while fetching progress.",
        stopped: @@scraping_status[:stopped],
        current: @@progress[:current],
        total: @@progress[:total],
        successful_count: @@progress[:successful].size,
        unsuccessful_count: @@progress[:unsuccessful].size,
        invalid_links_count: @@progress[:invalid_links].size,
        successful_details: @@progress[:successful],
        unsuccessful_details: @@progress[:unsuccessful],
        invalid_details: @@progress[:invalid_links],
        current_log: "Error occurred in progress tracking."
      }, status: :internal_server_error
    end
  end

  # Reset scraping state and clear cache
  def reset
    begin
      Rails.logger.info("[reset] Starting reset process...")

      # Step 1: Clean temporary files
      clean_tmp_directory
      Rails.logger.info("[reset] Temporary files cleaned successfully.")

      # Step 2: Clean up state files
      clean_up_state_files
      Rails.logger.info("[reset] State files cleaned up successfully.")

      # Step 3: Reset progress variables
      reset_progress
      Rails.logger.info("[reset] Progress variables reset successfully: #{@@progress.inspect}")

      # Step 4: Ensure stopped status is cleared
      @@scraping_status[:stopped] = false
      Rails.logger.info("[reset] Scraping status reset to: #{@@scraping_status.inspect}")

      Rails.logger.info("[reset] Reset process completed successfully.")
      render json: { status: "success", message: "Scrape again. 😎" }
    rescue StandardError => e
      Rails.logger.error("[reset] Error during reset: #{e.message}\n#{e.backtrace.join("\n")}")
      render json: { status: "error", message: "Failed to reset. Please try again." }, status: :internal_server_error
    end
  end

  def clean_tmp_directory
    tmp_path = Rails.root.join("tmp")
    Rails.logger.info("[clean_tmp_directory] Cleaning temporary directory: #{tmp_path}")

    Dir.foreach(tmp_path) do |file|
      file_path = File.join(tmp_path, file)

      # Skip directories like "." and ".."
      next if file == "." || file == ".."

      # Delete the file or directory
      if File.directory?(file_path)
        Rails.logger.info("[clean_tmp_directory] Deleting directory: #{file_path}")
        FileUtils.rm_rf(file_path) # Remove directories recursively
      else
        Rails.logger.info("[clean_tmp_directory] Deleting file: #{file_path}")
        File.delete(file_path) if File.exist?(file_path) # Remove files
      end
    end

    Rails.logger.info("[clean_tmp_directory] Temporary files deleted from #{tmp_path}.")
  end

  def fetch
    # Clean temporary files and reset progress before starting
    clean_tmp_directory

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

  def stop_scraping
    begin
      file_path = Rails.root.join("tmp", "scraping_stopped")
      File.write(file_path, "") # Marker file to signal stop
      Rails.logger.info("Stop marker file created at #{file_path}.")

      @@scraping_status[:stopped] = true # In-memory flag to signal stop
      @@current_log = "Scraping stopped by user."
      Rails.logger.info(@@current_log)

      render json: { status: "stopped", message: "Scraping has been stopped successfully." }
    rescue StandardError => e
      Rails.logger.error("Error stopping scraping: #{e.message}")
      render json: { status: "error", message: "Failed to stop scraping. Please try again." }, status: :internal_server_error
    end
  end

  def scrape_youtube_data(youtube_link, id_tag, today_date)
    unless youtube_link =~ /\Ahttps:\/\/(www\.)?youtube\.com\/watch\?v=[\w\-]{11}\z/
      @@progress[:invalid_links] << { idTag: id_tag, YoutubeLink: youtube_link }
      Rails.logger.info("Invalid YouTube link: #{youtube_link}")
      return false
    end

    begin
      Rails.logger.info("Processing YouTube link: #{youtube_link}")

      # Define S3 keys for each file type
      s3_keys = {
        title: "Video_Title/#{id_tag}-Title.txt",
        description: "Video_Description/#{id_tag}-Description.txt",
        thumbnail: "Thumbnail_Image/#{id_tag}-Image.jpg",
        video: "Video/#{id_tag}-Video.mp4"
      }

      # Skip files that already exist in S3
      existing_keys = s3_keys.select { |_, key| s3_file_exists?("#{today_date}-Batch/#{key}") }
      Rails.logger.info("Skipping already existing files in S3 for #{youtube_link}: #{existing_keys.keys.join(', ')}")

      # Fetch only files that do not exist
      title_success = existing_keys[:title] || fetch_youtube_data(youtube_link, "title", s3_keys[:title], today_date)
      description_success = existing_keys[:description] || fetch_youtube_data(youtube_link, "description", s3_keys[:description], today_date, true)
      thumbnail_success = existing_keys[:thumbnail] || fetch_youtube_data(youtube_link, "thumbnail", s3_keys[:thumbnail], today_date, true)
      video_success = existing_keys[:video] || fetch_youtube_video(youtube_link, s3_keys[:video], today_date)

      # Track success or failure
      if title_success || description_success || thumbnail_success || video_success
        @@progress[:successful] << {
          idTag: id_tag,
          YoutubeLink: youtube_link,
          title_success: title_success,
          description_success: description_success,
          thumbnail_success: thumbnail_success,
          video_success: video_success
        }
        Rails.logger.info("Partial or full success for: #{youtube_link}")
      else
        @@progress[:unsuccessful] << { idTag: id_tag, YoutubeLink: youtube_link }
        Rails.logger.error("All attempts failed for: #{youtube_link}")
      end

      true
    rescue StandardError => e
      @@progress[:unsuccessful] << { idTag: id_tag, YoutubeLink: youtube_link }
      Rails.logger.error("Error processing #{youtube_link}: #{e.message}")
      false
    end
  end

  private

  def fetch_youtube_video(link, s3_key, today_date)
    full_s3_key = "#{today_date}-Batch/#{s3_key}"

    unless check_scraping_status
      @@current_log = "Scraping stopped while downloading video for #{link}."
      Rails.logger.info(@@current_log)
      return false
    end

    if s3_file_exists?(full_s3_key)
      @@current_log = "Skipping video for #{link}: File already exists on S3."
      Rails.logger.info(@@current_log)
      return true
    end

    folder_name = Rails.root.join("tmp", "Video")
    FileUtils.mkdir_p(folder_name)

    temp_video_path = folder_name.join(File.basename(s3_key))
    video_command = "yt-dlp --proxy '' -f 'bestvideo[ext=mp4][height<=1080]+bestaudio[ext=m4a]/best[ext=mp4][height<=1080]' -o '#{temp_video_path}' '#{link}'"


    @@current_log = "Downloading video for #{link}..."
    Rails.logger.info(@@current_log)

    `#{video_command}`

    if $? != 0
      @@current_log = "Error downloading video: #{link}: Command failed with status #{$?.exitstatus}"
      Rails.logger.error(@@current_log)
      return false
    end

    unless check_scraping_status
      @@current_log = "Scraping stopped after downloading video for #{link}."
      Rails.logger.info(@@current_log)
      File.delete(temp_video_path) if File.exist?(temp_video_path)
      return false
    end

    unless File.exist?(temp_video_path)
      @@current_log = "[error] Failed to download video for #{link}. File does not exist."
      Rails.logger.error(@@current_log)
      return false
    end

    upload_to_s3(full_s3_key, temp_video_path)

    File.delete(temp_video_path)

    @@current_log = "[info] Video successfully downloaded and uploaded for #{link}."
    Rails.logger.info(@@current_log)
    true
  rescue StandardError => e
    @@current_log = "Error downloading video for #{link}: #{e.message}"
    Rails.logger.error(@@current_log)
    false
  end

  def fetch_youtube_data(link, data_type, s3_key, today_date, is_file = false)
    unless check_scraping_status
      @@current_log = "Scraping stopped while processing #{data_type} for #{link}."
      Rails.logger.info(@@current_log)
      return false
    end

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

    unless check_scraping_status
      @@current_log = "Scraping stopped after processing #{data_type} for #{link}."
      Rails.logger.info(@@current_log)
      return false
    end

    folder_name = Rails.root.join("tmp", case data_type
                  when "title" then "Video_Title"
                  when "description" then "Video_Description"
                  when "thumbnail" then "Thumbnail_Image"
                  else raise "Unknown data type #{data_type}"
                  end)
    FileUtils.mkdir_p(folder_name)

    if data_type == "title"
      if result.strip.empty?
        Rails.logger.error("Failed to fetch title for #{link}.")
        return false
      end

      local_file_path = folder_name.join(File.basename(s3_key))
      File.write(local_file_path, result.strip)

      upload_to_s3("#{today_date}-Batch/#{s3_key}", local_file_path)
      File.delete(local_file_path) if File.exist?(local_file_path)

    elsif is_file
      system(command)

      file_path = Dir.glob("#{output_file}*").find { |f| File.exist?(f) }
      return false unless file_path

      local_file_path = folder_name.join(File.basename(s3_key))
      FileUtils.mv(file_path, local_file_path)

      upload_to_s3("#{today_date}-Batch/#{s3_key}", local_file_path)
      File.delete(local_file_path) if File.exist?(local_file_path)
    end

    true
  rescue StandardError => e
    @@current_log = "Error processing #{data_type} for #{link}: #{e.message}"
    Rails.logger.error(@@current_log)
    false
  end

  def reset_progress
    Rails.logger.info("[reset_progress] Resetting progress variables.")
    @@progress = {
      current: 0,
      total: 0,
      successful: [],
      unsuccessful: [],
      invalid_links: []
    }
    @@current_log = ""
    Rails.logger.info("[reset_progress] Progress reset to: #{@@progress.inspect}")
  end

  # Finalize scraping and clean up
  def finalize_scraping(today_date)
    Rails.logger.info("Finalizing the scraping process...")
    @@current_log = "Finalizing the scraping process..."

    clean_up_state_files

    Rails.logger.info("Scraping process finalized. Status reset.")
  end

  def clean_up_state_files
    state_file = Rails.root.join("tmp", "scraping_stopped")
    if File.exist?(state_file)
      Rails.logger.info("[clean_up_state_files] Deleting state file: #{state_file}")
      File.delete(state_file)
    else
      Rails.logger.info("[clean_up_state_files] No state file found to delete: #{state_file}")
    end
    Rails.logger.info("[clean_up_state_files] State files cleaned up successfully.")
  end

  def check_scraping_status
    stopped = scraping_stopped?
    Rails.logger.info("check_scraping_status invoked: scraping_stopped? returned #{stopped}")

    if stopped
      @@current_log = "Scraping stopped. Finalizing results..."
      Rails.logger.info(@@current_log)
      finalize_scraping(Date.today.strftime("%Y-%m-%d")) # Finalize results
      return false # Indicate that scraping should stop
    end

    true # Continue scraping if not stopped
  end

  def scraping_stopped?
    file_exists = File.exist?(Rails.root.join("tmp", "scraping_stopped"))
    stopped_flag = @@scraping_status[:stopped]

    Rails.logger.info("Scraping stopped? File exists: #{file_exists}, Flag: #{stopped_flag}")

    file_exists || stopped_flag
  end


  def handle_new_csv(csv_data, today_date)
    csv_data.each_with_index do |row, index|
      # Check if scraping was stopped before processing the row
      if scraping_stopped?
        Rails.logger.info("Scraping stopped detected before processing row #{index + 1}.")
        finalize_scraping(today_date) # Finalize results and exit
        return
      end

      youtube_link = row["YoutubeLink"]
      id_tag = row["idTag"]

      begin
        # Log progress for the current row
        Rails.logger.info("Processing row #{index + 1}/#{csv_data.size}: #{youtube_link}")
        scrape_youtube_data(youtube_link, id_tag, today_date)

        # Update progress after processing the row
        @@progress[:current] = index + 1

        # Check if scraping was stopped after processing the row
        if scraping_stopped?
          Rails.logger.info("Scraping stopped detected after processing row #{index + 1}.")
          finalize_scraping(today_date) # Finalize results and exit
          return
        end
      rescue StandardError => e
        # Log any errors that occur during processing
        Rails.logger.error("Error processing row #{index + 1}: #{e.message}")
        @@progress[:unsuccessful] << { idTag: id_tag, YoutubeLink: youtube_link }
      end
    end

    # Finalize after processing all rows
    finalize_scraping(today_date)
    Rails.logger.info("All rows processed successfully.")
  end

  def s3_file_exists?(key)
    s3_client.bucket(ENV["AWS_BUCKET_NAME"]).object(key).exists?
  rescue Aws::S3::Errors::ServiceError => e
    Rails.logger.error("Error checking S3 file existence for #{key}: #{e.message}")
    false
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
