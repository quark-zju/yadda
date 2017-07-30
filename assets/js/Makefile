.PHONY: default

default: yadda-home.js yadda-default-code.js

%.js: %.coffee
	coffee -c $<

clean:
	-rm -f yadda-home.js
