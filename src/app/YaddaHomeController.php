<?php

final class YaddaHomeController extends PhabricatorController {
  public function shouldAllowPublic() {
    return true;
  }

  public function handleRequest(AphrontRequest $request) {
    require_celerity_resource('yadda-home', 'yadda');
    $title = pht('Yadda');
    $page = $this->newPage()->setTitle($title);
    return $page;
  }
}
