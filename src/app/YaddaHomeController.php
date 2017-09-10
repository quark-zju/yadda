<?php

final class YaddaHomeController extends PhabricatorController {
  public function shouldAllowPublic() {
    return true;
  }

  public function handleRequest(AphrontRequest $request) {
    require_celerity_resource('javelin-request');
    require_celerity_resource('javelin-stratcom');
    require_celerity_resource('phabricator-keyboard-shortcut');
    require_celerity_resource('phabricator-notification');
    require_celerity_resource('yadda-home', 'yadda');
    require_celerity_resource('yadda-css', 'yadda');

    $viewer = $request->getUser();
    $title = pht('Yadda');
    $page = $this->newPage()->setTitle($title);
    $root = phutil_tag_div('yadda-root');
    $page->appendChild($root);
    if ($viewer->getUserName() === null) {
      // If not logged in, Conduit API cannot be used. Provide a static initial
      // state in this case.
      $state = YaddaQueryConduitAPIMethod::query($viewer, array());
      $state_div = phutil_tag('div', array(
        'class' => 'yadda-non-logged-in-state',
        'style' => 'display: none',
      ), phutil_json_encode($state));
      $page->appendChild($state_div);
    }
    return $page;
  }
}
