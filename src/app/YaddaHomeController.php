<?php

final class YaddaHomeController extends PhabricatorController {
  public function shouldAllowPublic() {
    return true;
  }

  public function handleRequest(AphrontRequest $request) {
    require_celerity_resource('javelin-request');
    require_celerity_resource('phabricator-keyboard-shortcut');
    require_celerity_resource('phabricator-notification');
    require_celerity_resource('yadda-home', 'yadda');
    require_celerity_resource('yadda-css', 'yadda');

    $viewer = $request->getUser();
    $title = pht('Yadda');
    $page = $this->newPage()->setTitle($title);
    $root = phutil_tag_div('yadda-root');
    $page->appendChild($root);
    return $page;
  }
}
