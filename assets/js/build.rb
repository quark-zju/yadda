#!/usr/bin/env ruby

require 'fileutils'

DEST = if ENV['DEV']
         'yadda-app.dev.js'
       else
         'yadda-app.min.js'
       end

FileUtils.rm_f %w[yadda-app.js yadda-app.min.js]

File.open('yadda-tmp.coffee', 'w') do |f|
  f.puts "yaddaDefaultCode = '''"
  f.write File.read('yadda-default-code.coffee').gsub('\\', '\\\\\\\\')
  f.puts "'''"
  f.write File.read('yadda-home.coffee')
end

exit 1 unless system'coffee -c yadda-tmp.coffee'

# Celerity fails to minify the resource. Let's do it manually
files = Dir['../vendor/{lodash,moment,coffeescript}/*.js'].sort + ['yadda-tmp.js']
if ENV['DEV']
  File.open(DEST, 'w') do |f|
    files.each { |p| f.puts File.read(p) }
  end
else
  exit 2 unless system "uglifyjs --comments '/icense/' -d __DEV__=0 -o #{DEST} #{files * ' '}"
end

# Add "@do-not-minify" to bypass Celerity
content = File.read(DEST)
header = <<'EOS'
/**
 * @do-not-minify
 * @provides yadda-home
 */
EOS

# uglifyjs does not handle react.js well, write it manually
File.open(DEST, 'w') do |f|
  f.write(header)
  %w[
    ../vendor/react/react.min.js
    ../vendor/react/react-dom.min.js
  ].each do |path|
    f.write(File.read(path))
  end
  f.write(content)
end

FileUtils.rm_f ['yadda-tmp.coffee', 'yadda-tmp.js']
system 'celerity map'
