require 'sqs/helper'

require 'em-http'

module SQS
  def self.run(&block)
    # Ensure graceful shutdown of the connection to the broker
    DaemonKit.trap('INT') { ::EM.stop }
    DaemonKit.trap('TERM') { ::EM.stop }

    # Start our event loop
    DaemonKit.logger.debug("EM.run")
    EM.run(&block)
  end
  
  class Queue
    include Helper

    def initialize(name)
      @config = Qanat.load('sqs')
      @name = name
    end
    
    def logger
      DaemonKit.logger
    end
    
    def delete_msg(handle)
      logger.info "Deleting #{handle}"
      request_hash = generate_request_hash("DeleteMessage", 'ReceiptHandle' => handle)
      http = EventMachine::HttpRequest.new("http://queue.amazonaws.com/#{@name}").get :query => request_hash, :timeout => 10
      http.callback do
        code = http.response_header.status
        if code != 200
          logger.error "SQS delete returned an error response: #{code} #{http.response}"
        end
      end
    end
    
    def receive_msg(&block)
      request_hash = generate_request_hash("ReceiveMessage", 
        'MaxNumberOfMessages'  => 1, 
        'VisibilityTimeout' => 3600)
      http = EventMachine::HttpRequest.new("http://queue.amazonaws.com/#{@name}").post :body => request_hash, :timeout => 10
      http.callback do
        code = http.response_header.status
        doc = parse_response(http.response)
        handle_el = doc.find_first('//sqs:ReceiptHandle')
        id_el = doc.find_first('//sqs:MessageId')
        md5_el = doc.find_first('//sqs:MD5OfBody')
        body_el = doc.find_first('//sqs:Body')
        if id_el && md5_el && body_el && handle_el
          message_id = id_el.content.strip
          checksum = md5_el.content.strip
          body = body_el.content.strip
          handle = handle_el.content.strip
          
          if checksum != Digest::MD5.hexdigest(body)
            logger.info "SQS message does not match checksum, ignoring..."
          else
            logger.info "Queued message, SQS message id is: #{message_id}"
            block.call body
            delete_msg(handle)
          end
        elsif code == 200
          logger.info "Queue #{@name} is empty"
        else
          logger.error "SQS returned an error response: #{code} #{http.response}"
          # TODO parse the response and print something useful
          # TODO retry a few times with exponentially increasing delay
        end
      end
      http.errback do
        # TODO a decent log message here
        logger.error "fail"
        # TODO dump the message to a temp file and write a utility to re-send dumped messages
      end
    end
    
  end
end