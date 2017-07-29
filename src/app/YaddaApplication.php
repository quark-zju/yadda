<?php

final class YaddaApplication extends PhabricatorApplication {

  public function getName() {
    return pht('Yadda');
  }

  public function getBaseURI() {
    return '/yadda/';
  }

  public function getIconName() {
    return 'fa-list-alt';
  }

  public function getShortDescription() {
    return 'Yet another dashboard';
  }

  public function getRoutes() {
    return array(
      '/yadda/' => 'YaddaHomeController',
    );
  }
}
