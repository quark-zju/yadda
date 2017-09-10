<?php

final class YaddaConfigOptions extends PhabricatorApplicationConfigOptions {

  public function getName() {
    return pht('Yadda');
  }

  public function getDescription() {
    return pht('Configure Yadda.');
  }

  public function getGroup() {
    return 'apps';
  }

  public function getKey() { // Affects URL
    return 'yadda';
  }

  public function getOptions() {
    return array(
        $this->newOption('yadda.append-script', 'string', '')
            ->setSummary(pht('Extra code for the default UI script.'))
            ->setDescription(
              pht("If set, it will be appended to the built-in script. ".
                  "JSON encoded string will be decoded automatically."))
            ->addExample(
              "shortcutKey 'F', 'Go to Feed.', -> location.href = '/feed'",
              pht('Add shortcut key'))
            ->addExample(
              "stylesheet = stylesheet.replace /solid/, 'dashed'",
              pht('Change style'))
            ->addExample(
              '"orig = @render\\n@render = (state) ->\\n  '.
              'div style: {margin: 10},\\n    orig(state)\\n"',
              pht('JSON encoded string')),
    );
  }

}
