Gem::Specification.new do |gem|
  gem.name = 'async_observer'
  gem.authors = ['Brigade Engineering', 'Tom Dooner']
  gem.email = ['eng@brigade.com', 'tom.dooner@brigade.com']
  gem.homepage = 'https://github.com/causes/async_observer'
  gem.license = 'MIT'
  gem.required_ruby_version = '>= 1.9.3'
  gem.version = '0.2.0'
  gem.executables << 'worker'
  gem.files = Dir['lib/{,**/}*']
  gem.description = 'Async Observer'
  gem.summary = 'Async Observer'
end
