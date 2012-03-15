require 'sprite_factory'
#require 'image_science'
require 'rmagick'
require 'tmpdir'
require 'tempfile'
require 'fileutils'

# Image processing with chainable operations.
class ImagePipe
  attr_accessor :file_globs
  
  @@temp_dirs = []
  @@defaults = {verbose: false, file_names: nil}
  # file_names is used internally to denote the original file names of each temp file in the file globs when using temp files

  at_exit do
    # Yes, we do slowly amass temporary directories. Yes technically this is a memory leak but its small and it gets fixed at the end right?
    @@temp_dirs.each do |dir|
      puts "removing #{dir}"
      FileUtils.remove_entry_secure dir
    end
  end

  def initialize(*args)
    raise "Pipe requires 1 or 2 arguments" unless 3 > args.length and args.length > 0

    # if the argument is a list of glob strings
    if args[0].respond_to? :each and args[0].respond_to? :length
      @file_globs = args[0]
    # if the argument is a glob string or regex
    else
      @file_globs = [args[0]]
    end
    @options = ( args.length == 2 ? @@defaults.merge(args[1]||{}) : @@defaults )
  end

  #def add(glob)
  #  return ImagePipe.new(@file_globs + [glob].flatten)
  #end


  ##
  # Resizes the image to +width+ and +height+ using a cubic-bspline
  # filter and yields the new image.
  def resize(*args)
    image_science(:resize, *args)
  end


  ##
  # Creates a proportional thumbnail of the image scaled so its longest
  # edge is resized to +size+ and yields the new image.
  def thumbnail(width, height = nil)
    rmagick() {|rm| rm.resize_to_fit(width, height)}
    #self.image_science(:thumbnail, *args)
    #self.rmagick
    
  end


  ##
  # Creates a +width+ px by +height+ px thumbnail of the pipe's images cropping 
  # the longest edge to match the shortest edge, resizes to +size+, and 
  # yields the new pipe.
  def cropped_thumbnail(width, height)
    puts width
    rmagick {|rm| rm.resize_to_fill(width, height)}
    #self.image_science(:cropped_thumbnail, width) # TODO: non-square thumbnails
  end


  def trim(arg)
    rmagick {|rm| rm.trim(arg)}
  end


  def shave(*args)
    rmagick {|rm| rm.shave(*args)}
  end


  ##
  # Runs SpriteFactory generating a single sprite image from all the images in the pipe.
  def sprite_factory(opts)
    # Sprite factory requires the files to be in a single directory.
    # Copy the files to a temp directory if they are not in one already
    return self.copy_to_temp_dir.sprite_factory(opts) if @options[:temporary_file_map].nil?

    puts "Running Sprite Factory" if @options[:verbose] == true
    dir = File.dirname( self.file_globs[0] )

    # Running SpriteFactory and swapping out temporary file names for the image pipe's original file names in the css
    SpriteFactory.run!( dir, opts ) do |images|
      rules = []
      images.each do |basename, img|
        new_basename = original_basename("#{basename}.png",".*").gsub(/[. ]/, "_")
        css = img[:style].sub(Regexp.new("^ *.#{opts[:selector]||""}#{basename} "), '')
        rules << "#{opts[:selector]||""}#{new_basename} {#{css}}"
      end
      rules.join("\n")
    end

    # Saving the sprite factory to a new image pipe
    ImagePipe.new(opts[:output_image], Hash.new(@options||{}).delete(:temporary_files) )
  end


  def rmagick
    build_temp_file_pipe do |in_f, out_f, f_name|
      # Run the rmagick method on the file
      img_in = Magick::ImageList.new(in_f)
      img_out = yield img_in, f_name
      img_out = img_in unless img_out.respond_to?(:write) and img_out.respond_to?("destroy!".to_sym)

      #img_out.destroy! # cleanup early, kill memory leaks!
      img_out.write(out_f).destroy!
      GC.start
    end
  end


  ##
  # Returns an image pipe containing temprorary files copied from this image pipe's files.
  def copy_to_temp_dir()
    build_temp_file_pipe { |in_f, out_f| FileUtils.cp(in_f, out_f) }
  end


  def save(dir, &block)
    files.each do |f|
      basename = original_basename(f)
      # allows a proc to customize the file name
      unless block.nil?
        basename = block.call(basename)
      end
      # save the file to the new location
      FileUtils.cp( f, File.join(dir, basename) )
    end
    return self
  end


  def files() # locates and caches the files on demand
    file_sets = file_globs.collect { |glob| Dir.glob(glob) }
    files = file_sets.flatten.reject {|f| f == '.' or f == '..' or File.directory?(f) == true}
    return @files = files.flatten
  end


  private


  ##
  # gets the orignal basename of a path regardless of whether it is a temporary file or not.
  def original_basename(path, arg = nil)
    unless @options[:temporary_file_map].nil?
      path = @options[:temporary_file_map][File.basename(path)][:name]
    end
    if arg.nil?
      File.basename( path )
    else
      File.basename( path, arg )
    end
  end


  ##
  # yields each file in this pipe and a corresponding temp file to save it too to generate a new pipe
  def build_temp_file_pipe
    @@temp_dirs.push ( dir = Dir.mktmpdir )
    temp_files = []
    if @options[:verbose] == true
      i = 0
      STDOUT.sync = true
      last_msg = ""
    end
    files.each do |input_file_path|
      # Verbose debugging info
      if @options[:verbose] == true
        i += 1
        ram_usage = (`ps -o rss= -p #{Process.pid}`.to_f / 1000).round(2) # MB
        msg = "\r [#{'|'*(i*10/files.length)}#{' '*(10-i*10/files.length)}]  File: #{File.basename(input_file_path)}"
        msg = (msg.length >= 80)? msg[0..80] + '...' : msg + ' '*(80 + 4 - msg.length) # fixed length file name
        msg += "  RAM: #{ram_usage}MB  (#{i}/#{files.length} completed) "
        print msg
      end

      # Generating and storing the temp file
      temp_files.push( output_file = Tempfile.new(['lol', '.png'], dir) )
      output_file.close(false) # close the file but don't unlink it. This kills the memory leak.
      # Yielding
      yield( input_file_path, output_file.path, original_basename(input_file_path) )
    end
    # TODO: a way of getting file names across temp file and non temp file image pipes!
    file_names = files.collect{|f| original_basename(f)}
    # Mapping each temporary file's basename to their original file name and temporary file object
    temp_file_map = file_names.collect do |name|
      t = temp_files[ file_names.index(name) ]
      [File.basename(t.path), {name: name, temp_file: t} ]
    end

    if @options[:verbose] == true
      puts "\n"
    end
    # return a new image pipe containing all the output as a glob of the temporary directory
    return ImagePipe.new( [File.join(dir, "*")], @options.clone.merge({temporary_file_map: Hash[temp_file_map]}) )
  end


  ##
  # runs a image science method on the images in this pipe returning the new pipe instance containing the
  # image science processed images (temp files)
  def image_science(method, *args)
    puts "Running ImageScience.#{method.to_s} (  #{args.inspect}  )" if @options[:verbose] == true
    self.build_temp_file_pipe do |in_f, out_f|
      # Run the image science method on each file
      ImageScience.with_image(in_f) { |img| img.method(method).call(*args) { |out_img| out_img.save(out_f) } }
    end
  end

end