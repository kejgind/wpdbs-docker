<?php
/**
 * Plugin Name: Mailpit SMTP
 * Description: Routes all outgoing mail to Mailpit (local dev mail catcher).
 */

add_action('phpmailer_init', function ($phpmailer) {
    $phpmailer->isSMTP();
    $phpmailer->Host       = 'mailpit';
    $phpmailer->Port       = 1025;
    $phpmailer->SMTPAuth   = false;
    $phpmailer->SMTPSecure = '';
});
