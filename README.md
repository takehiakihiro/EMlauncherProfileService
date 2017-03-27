# EMlauncherProfileService
iOS OTA Profile service for EMLauncher

## Install

このリポジトリを取得して、profile-service.rbを適当なディレクトリへと設置してください。

現状の設定ではSECPサービスのためのクライアントとの通信にはTCPポートの8443番を使用するのでファイアウォールなどの設定でクライアントとの通信を許可してください。
ポート番号を変更するにはスクリプトの49行目@@portを変更します。

```
    49	# SECP service port number.
    50	@@port = 8443
```

Ruby開発環境ではruby 2.4.0p0を利用しています。
EMlauncherのMySQLデータベースとの通信のためにmysql2を、Profile Serviceで配布されるWebClipのアイコンの生成にbase64を使用しています。

EMlauncherからのProfile Serviceの要求の参照と、Profile Serviceによって取得しrたテスト端末のUDIDの記録のためにEMlauncherのMySQLテーブルへのアクセスが必要となるので、EMlauncher側でデータベースのテーブル(emlauncher.ios_device_infoのみで可)に対してのDELETE, INSERT, SELECT, UPDATE権限を付与しておいてください。

MySQLサーバーへの接続情報はスクリプトの484行目、@@mysql_connection_infoを適当に修正します。
EMlauncherで使用するデータベースの名称なども必要であれば変更します。

```
    55	# Connection information for EMlauncher MySQL Server
    56	@@mysql_connection_info = {:host => 'emlauncher.example.com', :username => 'emlauncher', :password => 'password'}
    57	# MySQL database name for EMlauncher
    58	@@table_name = "emlauncher"
```

SECPサービスを稼働させるサーバーのホスト名(FQDN)を@@addressに設定します。

```
    48	# explicitly set this to host ip or name if more than one interface exists
    49	@@address = "secp.example.com"
```

Appleが提供するオリジナルのスクリプトでは自己証明書を使う前提となっているため、SSL通信やSECPの証明書の作成に使用するためのSSL証明書はスクリプトの起動時に自動的に作成されます。
同時に端末にインストールするRoot CAの証明書も自動的に生成され、以下の様にSECPサービスのサーバーURLのトップページへとアクセスして「root certificate」のリンクをクリックすることで自己証明書用のRoot CAの証明書を端末へとインストールすることができます。(※この場合、認証局の証明書は自己証明書、俗に言う「オレオレ証明書」となるため、端末へのインストールには警告が表示されます)

```
https://secp.example.com:8443/
```

また、このページの「enroll」リンクをクリックしてSECPサービスの動作確認用にWebClipのプロファイルを端末へとインストールすることができます。
インストールされるWebClipは単純な@@emlauncher_urlに設定されたURLを開くだけのプロファイルです。

EMlauncher向けの実装では、オリジナルに若干手を加えてLet's Encryptなどで取得した正規のSSL証明書を利用しての認証を行える様になっています。
例えばLet's Encryptで取得したサーバー証明書を使う場合にはprofile-service.rbを展開したディレクトリにLet's Encryptで取得したサーバー証明書のcert.pemをssl_cert.pemとして、chain.pemをssl_chain.pemとして、privkey.pemをssl_private.pemとしてそれぞれコピーすることで正規のSSL証明書を利用することができます。
※オリジナルが自己証明書を起動時に生成する仕組みとなっているため、profile-service.rb中の@@addressに設定されているドメイン名とSSL証明書に記録されているDNSネームが一致しない場合、スクリプトはSSL証明書を新たに作成しようとするので注意してください。

スクリプト52行目の@@emlauncher_urlには、SECPサービスによって最終的にインストールされるWebClipをタップした際に接続するEMlauncherのWebサーバーURLを設定します。

```
    51	# EMlauncher URL.
    52	@@emlauncher_url = "https://emlauncher.example.com/"
```

Profile ServiceによってiOSテスト端末へとインストールされるWebClipのアイコンに使用する画像画像のファイルを同じくprofile-service.rbを展>開したディレクトリにWebClipIcon.pngというファイル名で保存しておくと、この画像がiOS端末のホーム画面に置かれるWebClipのアイコン画像に使われます。

スクリプトの60行目の@@emlauncher_titleを変更すると、SECPサービスで使われる証明書やプロフィールに表示されるタイトルやWebClipアイコンに表示されるキャプションを変更できます。

```
    59	# String for Display WebClip Icon title and other
    60	@@emlauncher_title = "EMlauncher"
```

54行目の@@secp_prefixはProfile Serviceで生成されるプロフィールのペイロード識別子のプレフィックスに使われる文字列です。

```
    53	# prefix for profile payload
    54	@@secp_prefix = "com.example"
```

