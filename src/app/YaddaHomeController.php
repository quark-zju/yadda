<?php

final class YaddaHomeController extends PhabricatorController {
  public function shouldAllowPublic() {
    return true;
  }

  public function handleRequest(AphrontRequest $request) {
    require_celerity_resource('javelin-request');
    require_celerity_resource('javelin-stratcom');
    require_celerity_resource('phui-button-bar-css');
    require_celerity_resource('phabricator-keyboard-shortcut');
    require_celerity_resource('phabricator-notification');
    require_celerity_resource('yadda-home-js', 'yadda');
    require_celerity_resource('yadda-css', 'yadda');

    $viewer = $request->getUser();
    $title = pht('Yadda');
    $page = $this->newPage()->setTitle($title);
    $root = phutil_tag_div('yadda-root');
    $page->appendChild($root);
    $append_script = PhabricatorEnv::getEnvConfig('yadda.append-script');
    $initial = array();
    if ($append_script) {
      // Try JSON decoding if it looks like encoded JSON list
      if (strncmp($append_script, "\"", 1) === 0) {
        $append_script = phutil_json_decode('['.$append_script.']')[0];
      }
      $initial['appendScript'] = $append_script;
    }
    if ($viewer->getUserName() === null) {
      // If not logged in, Conduit API cannot be used. Provide a static initial
      // state in this case.
      $state = YaddaQueryConduitAPIMethod::query($viewer, array());
      $initial['state'] = $state;
    }
    $initial_div = phutil_tag('pre', array(
      'class' => 'yadda-initial',
      'style' => 'display: none',
    ), phutil_json_encode($initial));
    $page->appendChild($initial_div);
    return $page;
  }
}
