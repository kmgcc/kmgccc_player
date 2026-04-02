use tauri::AppHandle;
use tauri::Manager;

use anyhow_tauri::IntoTAResult;

#[tauri::command]
pub async fn take_screenshot(
    app: AppHandle,
    resize_window: bool,
    target_width: u32,
    target_height: u32,
    recover_size: bool,
) -> anyhow_tauri::TAResult<String> {
    #[cfg(mobile)]
    {
        anyhow_tauri::bail!("Screenshot capture is not supported on Android");
    }
    #[cfg(not(mobile))]
    {
        let win = app.get_webview_window("main");

        let win = if let Some(win) = win {
            win
        } else {
            anyhow_tauri::bail!("Main window not found")
        };

        let orig_size = win.inner_size().into_ta_result()?;
        if resize_window {
            win.set_size(tauri::Size::Physical(tauri::PhysicalSize::new(
                target_width,
                target_height,
            )))
            .into_ta_result()?;
            win.set_resizable(false).into_ta_result()?;
        }

        let result: anyhow::Result<String> = {
            #[cfg(target_os = "windows")]
            {
                let win = win.clone();
                #[derive(serde::Deserialize, Debug)]
                struct ScreenshotResult {
                    data: String,
                }

                struct DevToolsRunner(tauri::WebviewWindow<tauri::Wry>);

                impl DevToolsRunner {
                    async fn run(
                        &self,
                        name: &'static str,
                        json_data: serde_json::Value,
                    ) -> anyhow::Result<String> {
                        use anyhow::Context;
                        use webview2_com::CallDevToolsProtocolMethodCompletedHandler;
                        let (os_sx, os_rx) = tokio::sync::oneshot::channel();

                        let json_data = serde_json::to_string(&json_data)
                            .expect("Failed to serialize JSON data");

                        self.0
                            .with_webview(move |webview| {
                                let ctl = webview.controller();
                                unsafe {
                                    let core_wv = ctl.CoreWebView2().unwrap();
                                    let name = webview2_com::pwstr_from_str(name);
                                    let json_data = webview2_com::pwstr_from_str(&json_data);
                                    let handler =
                                        CallDevToolsProtocolMethodCompletedHandler::create(
                                            Box::new(move |a, b| {
                                                os_sx.send((a, b)).expect(
                                            "Failed to send response from DevTools protocol method",
                                        );
                                                Ok(())
                                            }),
                                        );

                                    core_wv
                                        .CallDevToolsProtocolMethod(name, json_data, Some(&handler))
                                        .unwrap();
                                }
                            })
                            .unwrap();

                        let result = os_rx.await.unwrap();
                        result
                            .0
                            .map(|_| result.1)
                            .context("Failed to call DevTools protocol method")
                    }

                    // async fn set_viewport_size(
                    //     &self,
                    //     width: u32,
                    //     height: u32,
                    //     scale: f32,
                    // ) -> anyhow::Result<()> {
                    //     let json_data = serde_json::json!({
                    //         "width": width,
                    //         "height": height,
                    //         "deviceScaleFactor": scale,
                    //     });
                    //     self.run("Emulation.setDeviceMetricsOverride", json_data)
                    //         .await?;
                    //     Ok(())
                    // }

                    async fn take_screenshot(&self) -> anyhow::Result<String> {
                        let json_data = serde_json::json!({
                            "format": "png",
                            "optimizeForSpeed": true,
                        });
                        let res = self.run("Page.captureScreenshot", json_data).await?;

                        let res = serde_json::from_str::<ScreenshotResult>(&res)?;
                        // let data = base64::engine::general_purpose::STANDARD.decode(res.data)?;
                        // let img = image::load_from_memory_with_format(&data, image::ImageFormat::Png)?;
                        Ok(res.data)
                    }
                }

                let dev_tools_runner = DevToolsRunner(win);

                // dev_tools_runner
                //     .set_viewport_size(target_width, target_height, target_scale)
                //     .await
                //     .context("Failed to set viewport size")?;

                if resize_window {
                    tokio::time::sleep(std::time::Duration::from_secs(2)).await;
                }
                dev_tools_runner.take_screenshot().await
            }
            #[cfg(not(target_os = "windows"))]
            {
                anyhow_tauri::bail!(
                    "Screenshot capture using DevTools is not supported on this platform yet."
                )
            }
        };

        let result = result.into_ta_result()?;

        if resize_window {
            if recover_size {
                win.set_size(tauri::Size::Physical(orig_size))
                    .into_ta_result()?;
            }
            win.set_resizable(true).into_ta_result()?;
        }

        Ok(result)
    }
}
