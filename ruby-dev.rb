# -*- coding: utf-8 -*-

require 'rubygems'
gem 'pry',  '~> 0.9'
gem 'yard', '~> 0.8'

require 'set'
require 'json'
require 'fiber'

require 'pry'
begin
  require 'pry-doc'
rescue LoadError
end

require 'yard'

class RubyDev
  class Input
    def readline(prompt)
      Fiber.yield :read, prompt
    end

    # @return [Proc]
    attr_accessor :completion_proc
  end

  class Output
    # Yields some text to write to the widget.
    def write(data)
      Fiber.yield :write, data.to_s
      data.size
    end

    def <<(data)
      Fiber.yield :write, data.to_s
      self
    end

    # Yields a sequence of strings to print on the widget.
    def print(*strings)
      strings.each do |str|
        Fiber.yield :write, str.to_s
      end

      nil
    end

    # Yields a sequence of lines to print on the widget.
    #
    # Notice this needs to special case Array, since IO#puts does that
    # too. Instead of printing the result of Array#to_s, we need to print
    # every element on a new line.
    def puts(*lines)
      Fiber.yield :write, "\n" if lines.empty?

      lines.each do |line|
        if line.is_a? Array
          line.each { |sub_line| puts(sub_line) }
        else
          Fiber.yield :write, line.to_s.chomp + "\n"
        end
      end

      nil
    end
  end

  REPL = Struct.new(:fiber, :input, :output)

  def self.run
    o = new
    o.run
  ensure
    o.clean_up
  end

  @commands = {}

  def self.commands
    @commands
  end

  # Defines a handler for certain commands.
  #
  # @param [String] name Name fo the query to process.
  # @yieldparam [Hash] query JSON object received from the client
  # @yieldreturn [Hash] The object to send back to the client
  def self.command(name, &block)
    commands[name] = block
  end

  def initialize
    @input  = $stdin
    @output = $stdout
    @error  = $stderr

    @repls = {}
  end

  def clean_up
    # Nothing, for now
  end

  def commands
    self.class.commands
  end

  # Main loop
  #
  # Each line received from input is parsed as a JSON object, and the
  # corresponding handler is then run.
  def run
    @input.each_line do |line|
      begin
        query = JSON.parse(line)
        write_result dispatch(query)
      rescue JSON::JSONError => e
        @error.puts "#{e.class}: #{e.massage}"
      end
    end
  end

  # Attempts to run the correct handler for a certain type of query.
  def dispatch(query)
    if c = commands[query["type"]]
      instance_exec(query, &c)
    else
      {:success   => false,
       :error     => "Unknown query type: #{query["type"]}",
       :backtrace => []}
    end
  rescue Exception => e
    begin
      {:success => false, :error => "#{e.class}: #{e.message}",
       :backtrace => e.backtrace}
    rescue Exception
      # if the user is trying to break stuff, this can happen
      {:success => false, :error => "(unknown error)", :backtrace => []}
    end
  end

  # Writes an object to the output.
  #
  # @param [Hash] object Object to write to the output
  def write_result(object)
    @output.puts object.to_json
  end

  # Evalutes some arbitrary expression.
  command "eval" do |query|
    object = TOPLEVEL_BINDING.eval(query["code"], query["filename"],
                                   query["line"])
    {:success => true, :result => object.inspect}
  end

  # Searches for symbols that start with a given input.
  command "search-doc" do |query|
    search = query["input"]
    {:success => true, :completions => search_symbol(search).to_a}
  end

  # Recursively searches for a symbol.
  #
  # @param [String] search Prefix required for the symbol
  # @param [Module] mod Module to search for symbols in
  # @param [Set] seen Modules that have already been traversed
  #
  # @yieldparam [String] symbol Symbol that matches the research
  def search_symbol(search, mod = Object, seen = Set.new, &block)
    # Warnings are silenced because this code may trigger irrelevant deprecation
    # warnings (e.g. we're accessing ::Config).
    old_warn, $WARN = $WARN, false

    return to_enum(__method__, search, mod, seen) unless block
    return if seen.include? mod

    seen << mod

    possible_source = mod.name &&
      (mod.name.start_with?(search) ||
       search.start_with?(mod.name))

    if possible_source
      yield mod.name if mod.name.start_with? search

      [[mod.methods, "."], [mod.instance_methods, "#"]].each do |(mlist, sep)|
        mlist.each do |m|
          name = "#{mod.name}#{sep}#{m}"
          yield name if name.start_with? search
        end
      end
    end

    mod.constants(false).each do |const|
      begin
        val = mod.const_get(const)
      rescue NameError, LoadError
        next
      end

      if Module === val
        search_symbol(search, val, seen, &block)
      else
        begin
          const_name = "#{mod.name}::#{const}"
          yield const_name if const_name.start_with? search
        rescue Exception
          # just assume this is a weird (e.g. BasicObject) constant.
        end
      end
    end if possible_source || mod == Object
  ensure
    $WARN = old_warn
  end

  # Retrieves documentation-related informations about a specific symbol.
  command "object-info" do |query|
    symbol = query["symbol"]

    if doc = Pry::WrappedModule.from_str(symbol)
      # HACK: Pry::WrappedModule doesn't let us retrieve the wrapped object,
      # which we need if want to be able to use methods.

      wrapped = binding.eval(symbol)

      is_class = wrapped.is_a? Class

      superclass = wrapped.superclass if is_class

      {
        :success            => true,
        :symbol             => symbol,
        :type               => is_class ? :class : :module,
        :'source-location'  => doc.source_location,
        :superclass         => (superclass.name if superclass),
        :'included-modules' => doc.included_modules,

        :methods => {
          :new => wrapped.methods(false),
          :old => wrapped.methods - Class.instance_methods -
                  wrapped.methods(false),
        },
        :'instance-methods' => {
          :new => doc.instance_methods(false),
          :old => doc.instance_methods - doc.instance_methods(false),
        },

        :source => begin
                     doc.source
                   rescue Pry::CommandError
                   end,
        :doc    => begin
                     parse_doc(doc.doc)
                   rescue Pry::CommandError
                   end
      }
    elsif doc = Pry::Method.from_str(symbol)
      {
        :success           => true,
        :symbol            => symbol,
        :type              => :method,
        :'source-location' => doc.source_location,
        :language          => doc.source_type,
        :visibility        => doc.visibility,
        :signature         => (s = doc.signature) && s[s.index('(')..-1],
        :source            => begin
                                doc.source
                              rescue Pry::CommandError,
                                MethodSource::SourceNotFoundError
                              end,
        :doc               => begin
                                parse_doc(doc.doc)
                              rescue Pry::CommandError
                              end
      }
    else
      {:success   => false, :error => "Can't find object: #{symbol}",
       :backtrace => []}
    end
  end

  def parse_doc(doc)
    if doc
      docstring = YARD::DocstringParser.new.parse(doc).to_docstring
      doc_tag_to_hash(docstring)
    end
  end

  def doc_tag_to_hash(tag)
    case tag
    when YARD::Tags::Tag
      default       =  {
        :'tag-name' => tag.tag_name,
        :name       => tag.name,
        :types      => tag.types,
        :text       => tag.text
      }

      default.merge case tag
                    when YARD::Tags::OverloadTag
                      {
                       :parameters => tag.parameters,
                       :signature  => tag.signature,
                       :docstring  => doc_tag_to_hash(tag.docstring)
                      }
                    when YARD::Tags::OptionTag
                      {
                       :pair => doc_tag_to_hash(tag.pair)
                      }
                    when YARD::Tags::DefaultTag
                      {
                        :defaults => tag.defaults
                      }
                    else {}
                    end
    when YARD::Docstring
      {
        :text => tag,
        :tags => tag.tags.map { |t| doc_tag_to_hash(t) }
      }
    end
  end

  # Starts a REPL.
  command "repl-start" do |query|
    id = query["id"]

    @repls[id] = repl = REPL.new

    repl.input  = Input.new
    repl.output = Output.new

    repl.fiber = Fiber.new {
      Pry.start(TOPLEVEL_BINDING.eval(query["object"]),
                :input  => repl.input,
                :output => repl.output)
      repl.fiber = nil
    }

    {:succes => true}
  end

  # Processes a line of input.
  command "repl-handle" do |query|
    if repl = @repls[query["id"]]
      begin
        while request = repl.fiber.resume(query["argument"]) and
            request[0] != :read
          case request[0]
          when :write then
            write_result(:"repl-id" => query["id"],
                         :type      => "write",
                         :string    => request[1])
          end
        end


        write_result(:"repl-id" => query["id"],
                     :type      => "read",
                     :prompt    => request[1])
      rescue FiberError
      end

      {:success => true, :"repl-id" => query["id"]}
    else
      {:success => false, :error => "No such REPL: #{query["id"]}",
       :backtrace => [], :"repl-id" => query["id"]}
    end
  end

  # Kills a REPL.
  command "repl-stop" do |query|
    @repls.delete query["id"]
    {:success => true}
  end

  # Tries to autocomplete input in a REPL.
  command "repl-complete" do |query|
    if repl = @repls[query["id"]] and repl.fiber.alive?
      if proc = repl.input.proc
        {:success => true, :completions => proc.call(query["word"])}
      else
        {:success => true, :completions => []}
      end
    else
      {:success => false, :error => "No such REPL: #{query["id"]}",
       :backtrace => []}
    end
  end
end

RubyDev.run
