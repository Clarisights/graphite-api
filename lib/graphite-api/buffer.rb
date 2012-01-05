require 'thread'

module GraphiteAPI
  class Buffer
    attr_reader :leftovers,:mutex,:options,:new_records,:in_cache_mode

    def initialize(options)
      @mutex = Mutex.new
      @options = options
      @leftovers = Hash.new {|h,k| h[k] = Array.new}
      @new_records = []
      @in_cache_mode = !options[:cache_exp].nil?
      start_cleaner if in_cache_mode
    end

    def << hash
      mutex.synchronize do
        time = Utils.normalize_time(hash[:time],options[:slice])
        hash[:metric].each do |k,v|
          buffer[time][k] += v.to_f
          new_records << [time,k]
        end
      end
    end

    def stream(client_id,data)
      got_leftovers = data[-1,1] != "\n"
      data = data.split(/\n/)

      unless leftovers[client_id].empty?
        if (valid leftovers[client_id].last << data.first rescue nil)
          data.unshift(leftovers[client_id].pop << data.shift)
        end
        leftovers[client_id].clear
      end

      leftovers[client_id] << data.pop if got_leftovers
      data.each do |line|
        next unless valid line
        key,val,time = line.split
        self << {:metric => {key => val},:time => (Time.at(time.to_i) rescue Time.now)}
      end
    end

    def each
      mutex.synchronize do
        new_records.uniq.each do |time,key|
          yield [key,buffer[time][key],time]
        end
        new_records.clear
        buffer.clear unless in_cache_mode
      end
    end

    def valid(data)
      data =~ /^[\w|\.]+ \d+(?:\.\d)* \d+$/
    end

    def empty?
      buffer.empty?
    end

    def got_new_records?
      !new_records.empty?
    end
    
    def size
      buffer.values.map(&:values).flatten.size
    end

    private    
    def buffer
      @buffer ||= Hash.new {|h,k| h[k] = Hash.new {|h1,k1| h1[k1] = 0}}
    end
    
    def logger
      GraphiteAPI::Logger.instance
    end
    
    def clean(age)
      mutex.synchronize do
        logger.debug "[BufferCleaner] just woke up... Going to delete records older then #{age / 3600} hours (current size #{buffer.size})"
        now = Time.now.to_i
        [buffer,new_records].each {|o| o.delete_if {|t,k| now - t > age}}
        logger.debug "[BufferCleaner] After cleaning #{buffer.size}"        
      end
    end
    
    def start_cleaner
      GraphiteAPI::Scheduler.every(options[:cleaner_interval]) do
        clean(options[:cache_exp])
      end 
    end

  end
end