#!/usr/bin/env ruby

require 'fileutils'

File.open('yadda-tmp.coffee', 'w') do |f|
  f.puts "yaddaDefaultCode = '''"
  f.write File.read('yadda-default-code.coffee').gsub('\\', '\\\\\\\\')
  f.puts "'''"
  f.write File.read('yadda-home.coffee')
end

exit 1 unless system'coffee -c yadda-tmp.coffee'

# Celerity fails to minify the resource. Let's do it manually
files = Dir['../vendor/{codemirror,lodash,moment,coffeescript}/*.js'].sort + ['yadda-tmp.js']
exit 2 unless system "uglifyjs --comments '/icense/' -d __DEV__=0 -o yadda-app.min.js #{files * ' '}"

# Add "@do-not-minify" to bypass Celerity
content = File.read('yadda-app.min.js')
header = <<'EOS'
/**
 * @do-not-minify
 * @provides yadda-home
 */
EOS

# uglifyjs does not handle react.js well, write it manually
File.open('yadda-app.min.js', 'w') do |f|
  f.write(header)
  f.write(File.read('../vendor/react/react.min.js'))
  f.write(File.read('../vendor/react/react-dom.min.js'))
  f.write(content)
end

FileUtils.rm_f ['yadda-tmp.coffee', 'yadda-tmp.js']