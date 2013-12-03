
module FuseFS

    # A FuseFS that maps files from their original location into a new path
    # eg tagged audio files can be mapped by title etc...
    #
    # An in memory tree structure (Hash of Hashes) is used to maintain the tree structure. See {#node}
    class PathMapperFS < FuseDir

        # Convert FuseFS raw_mode strings to IO open mode strings
        def self.open_mode(raw_mode)
            case raw_mode
            when "r"
                "r"
            when "ra"
                "r" #not really sensible..
            when "rw"
                "r+"
            when "rwa"
                "a+"
            when "w"
                "w"
            when "wa"
                "a"
            end
        end

        # should raw file access should be used - useful for binary files
        # @return [Boolean]
        #   default is false
        attr_accessor :use_raw_file_access

        # should filesystem support writing through to the real files
        # @return [Boolean]
        #     default is false
        attr_accessor  :allow_write

        # Creates a new Path Mapper filesystem over an existing directory
        # @param [String] dir
        # @param [Hash] options
        # @yieldparam [String] file path to map
        # @yieldreturn [String] 
        # @see #initialize
        # @see #map_directory
        def PathMapperFS.create(dir,options={ },&block)
            pm_fs = PathMapperFS.new(options)
            pm_fs.map_directory(dir,&block) 
            return pm_fs
        end

        # Create a new Path Mapper filesystem
        # @param [Hash]  options
        # @option options [Boolean] :use_raw_file_access
        # @option options [Boolean] :allow_write
        def initialize(options = { })
            @root = { }
            @use_raw_file_access = options[:use_raw_file_access]
            @allow_write = options[:allow_write]
        end
        
        # Recursively find all files and map according to the given block
        # @param [String...] dirs directories to list
        # @yieldparam [String] file path to map
        # @yieldreturn [String] the mapped path
        # @yieldreturn nil to skip mapping this file
        def map_directory(*dirs)
            require 'find'
            Find.find(*dirs) do |file|
                new_path = yield file
                map_file(file,new_path) if new_path
            end
        end
        alias :mapDirectory :map_directory


        # Add (or replace) a mapped file
        #
        # @param [String] real_path pointing at the real file location
        # @param [String] new_path the mapped path
        # @param [Hash<Symbol,Object>] options other data for this path
        # @return [Hash]
        #    a node representing the mapped path. See {#node}
        def map_file(real_path,new_path,options = {})
            #split path into components 
            components = new_path.to_s.scan(/[^\/]+/)

            #create a hash of hashes to represent our directory structure
            new_file = components.inject(@root) { |directory, file|
                directory[file] ||= Hash.new().merge!(:pm_parent => directory)
            }
            new_file.merge!(options)
            new_file[:pm_real_path] = real_path.to_s
          
            return new_file
        end
        alias :mapFile :map_file
        
        # Retrieve node for a mapped path
        #
        # @param [String] path
        #
        # @return [Hash] represents the in memory node at path
        #    * :pm_real_path indicates a file node and references the backing file
        #    * :pm_parent references the parent directory node (nil if root)
        #    * Symbol keys represent arbitrary metadata for a node
        #    * :xattr if set with a [Hash] value represents extended attributes to be returned by the
        #      filesystem
        #    * String keys represent the mapped filenames within a directory
        #
        # @return nil if path does not exist in the filesystem
        def node(path)
            path_components = scan_path(path)

            #not actually injecting anything here, we're just following the hash of hashes...
            path_components.inject(@root) { |dir,file|
                break unless dir[file]
                dir[file]
            }
        end

        # Takes a mapped file name and returns the original real_path
        def unmap(path)
            possible_file = node(path)
            return possible_file ? possible_file[:pm_real_path] : nil
        end
        
        # Deletes files and directories.
        # Yields each {#node} in the filesystem and deletes it if the block returns true
        #
        # Useful if your filesystem is periodically remapping the entire contents and you need
        # to delete entries that have not been touched in the latest scan
        #
        # @yieldparam [Hash] filesystem node 
        # @yieldreturn [true,false] should this node be deleted
        def cleanup(&block)
           recursive_cleanup(@root,&block) 
        end


        # @!visibility private
        def directory?(path)
            possible_dir = node(path)
            possible_dir && !possible_dir[:pm_real_path]
        end

        # @!visibility private
        def contents(path)
            node(path).keys.select {|d| String === d}
        end

        # @!visibility private
        def file?(path)
            filename = unmap(path)
            filename && File.file?(filename)
        end

        # @!visibility private
        # only called if option :raw_reads is not set
        def read_file(path)
            IO.read(unmap(path))
        end

        # @!visibility private
        # We can only write to existing files
        # because otherwise we don't have anything to back it
        def can_write?(path)
            @allow_write && file?(path)
        end

        # @!visibility private
        def write_to(path,contents)
            File.open(unmap(path),"w") do |f|
                f.print(contents)
            end
        end

        # @!visibility private
        def size(path)
            File.size(unmap(path))
        end

        # @!visibility private
        def times(path)
            realpath = unmap(path)
            if (realpath)
                stat = File.stat(realpath)
                return [ stat.atime, stat.mtime, stat.ctime ]
            else
                # We're a directory
                return [0,0,0]
            end
        end

        # @!visibility private
        def xattr(path)
            result = node(path)[:xattr] || {}
        end

        # @!visibility private
        # Will create, store and return a File object for the underlying file
        # for subsequent use with the raw_read/raw_close methods
        # expects file? to return true before this method is called
        def raw_open(path,mode,rfusefs = nil)

            return false unless @use_raw_file_access

            return false if mode.include?("w") && (!@allow_write)

            @openfiles ||= Hash.new() unless rfusefs

            real_path = unmap(path)

            unless real_path
                if rfusefs
                    raise Errno::ENOENT.new(path)
                else
                    #fusefs will go on to call file?
                    return false
                end
            end

            file =  File.new(real_path,PathMapperFS.open_mode(mode))

            @openfiles[path] = file unless rfusefs

            return file
        end

        # @!visibility private
        def raw_read(path,off,sz,file=nil)
            file = @openfiles[path] unless file
            file.sysseek(off)
            file.sysread(sz)
        end

        # @!visibility private
        def raw_write(path,offset,sz,buf,file=nil)
            file = @openfiles[path] unless file
            file.sysseek(offset)
            file.syswrite(buf[0,sz])
        end

        # @!visibility private
        def raw_close(path,file=nil)
            unless file
                file = @openfiles.delete(path)
            end
            file.close if file
        end

        private
        
        def recursive_cleanup(dir_node,&block)
            dir_node.delete_if do |path,child| 
                # ignore symbols... that represent directory level information
                next false unless String === path
                if child.has_key?(:pm_real_path)
                    yield child
                else
                    recursive_cleanup(child,&block) 
                    !child.any? { |p,v| String === p }
                end
            end
        end
    end

end

