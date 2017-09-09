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
    return 'Yet Another Dashboard';
  }

  public function getRoutes() {
    return array(
      '/yadda/' => 'YaddaHomeController',
    );
  }
}
