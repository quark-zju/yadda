USE `phabricator_yadda`;

CREATE TABLE `yadda_userstate` (
  `userPHID` varbinary(64) NOT NULL,
  `value` longtext COLLATE {$COLLATE_TEXT} NOT NULL,
  UNIQUE KEY `userPHID` (`userPHID`)
) ENGINE=InnoDB DEFAULT  CHARSET={$CHARSET} COLLATE={$COLLATE_TEXT};
