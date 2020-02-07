# frozen_string_literal: true

module Paperclip
  module AttachmentExtensions
    # We overwrite this method to support delayed processing in
    # Sidekiq. Since we process the original file to reduce disk
    # usage, and we still want to generate thumbnails straight
    # away, it's the only style we need to exclude
    def process_style?(style_name, style_args)
      if style_name == :original && instance.respond_to?(:delay_processing?) && instance.delay_processing?
        false
      else
        style_args.empty? || style_args.include?(style_name)
      end
    end

    def reprocess_original!
      old_original_path = path(:original)
      reprocess!(:original)
      new_original_path = path(:original)

      if new_original_path != old_original_path
        @queued_for_delete << old_original_path
        flush_deletes
      end
    end

    # We overwrite this method to put a circuit breaker around
    # calls to object storage, to stop hitting APIs that are slow
    # to respond or don't respond at all and as such minimize the
    # impact of object storage outages on application throughput
    def save
      circuit_break! do
        flush_deletes unless @options[:keep_old_files]

        process = only_process
        @queued_for_write.except!(:original) if process.any? && !process.include?(:original)

        flush_writes
      end

      @dirty = false
      true
    end

    private

    STOPLIGHT_THRESHOLD = 10
    STOPLIGHT_COOLDOWN  = 30

    def circuit_break!(&block)
      Stoplight('object-storage', &block).with_threshold(STOPLIGHT_THRESHOLD).with_cool_off_time(STOPLIGHT_COOLDOWN).with_error_handler do |error, handle|
        if error.is_a?(Seahorse::Client::NetworkingError)
          handle.call(error)
        else
          raise error
        end
      end.run
    end
  end
end

Paperclip::Attachment.prepend(Paperclip::AttachmentExtensions)
