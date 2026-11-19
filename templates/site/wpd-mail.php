<?php
/**
 * Plugin Name: wpd mail to Mailpit
 * Description: Routes all outgoing mail to this site's Mailpit container (https://mail.<site>.test). Nothing leaves your machine.
 */
add_action('phpmailer_init', function ($mailer) {
    $mailer->isSMTP();
    $mailer->Host = 'mailpit';
    $mailer->Port = 1025;
    $mailer->SMTPAuth = false;
    $mailer->SMTPAutoTLS = false;
    $mailer->SMTPSecure = '';
});
