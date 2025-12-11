-- slicing_optimized.lua 
-- 适配 ffmpeg -i input.ts -ss START -to END -c copy out.mp4 命令格式
-- 新增鼠标框选裁剪功能

local msg = require "mp.msg"
local utils = require "mp.utils"
local options = require "mp.options"
local assdraw = require "mp.assdraw"

-- 状态变量
local cut_pos = nil  -- 记录开始时间点
local crop_area = nil  -- 记录裁剪区域 {x, y, w, h}
local crop_mode = false  -- 是否在框选模式
--local crop_step = 0  -- 框选步骤 (0:未开始, 1:等待选择左上角, 2:等待选择右下角)
--local crop_points = {}  -- 存储两个点
local osd_id = nil  -- OSD绘图ID

-- 鼠标框选相关变量
local mouse_move_binding = nil
local mouse_click_binding = nil
local crop_cursor = {x = 0, y = 0}  -- 鼠标位置
local crop_first_corner = nil  -- 第一个点（归一化坐标）
local crop_rect_drawn = false  -- 矩形是否已绘制

local o = {
    -- 视频文件设置
    output_ext = "mp4",
    
    -- 输出目录
    target_dir = "",  -- 空字符串 = 当前目录
    
    -- 文件名模式
    filename_pattern = "{basename}_{start}-{end}.{ext}",
    
    -- 裁剪设置
    enable_crop = true,  -- 启用裁剪功能
    crop_suffix = "_cropped",  -- 裁剪文件名后缀
    
    -- 裁剪编码设置（必须重新编码）
    crop_video_codec = "libx264",  -- 裁剪时使用的视频编码器
    crop_audio_codec = "aac",  -- 裁剪时使用的音频编码器
    
    -- ✅ 简化命令模板
    command_template = [[
        ffmpeg -i "$input" -ss $start_time -to $end_time -c copy "$output"
    ]],
    
    -- 裁剪命令模板
    crop_command_template = [[
        ffmpeg -i "$input" -ss $start_time -to $end_time -vf "crop=$crop_w:$crop_h:$crop_x:$crop_y" -c:v $crop_video_codec -c:a $crop_audio_codec "$output"
    ]],
    
    -- 框选UI设置
    draw_shade = true,  -- 绘制遮罩
    shade_opacity = "77",  -- 遮罩透明度
    draw_frame = true,  -- 绘制边框
    frame_border_width = 2,  -- 边框宽度
    frame_border_color = "EEEEEE",  -- 边框颜色
    draw_crosshair = true,  -- 绘制十字准线
    draw_text = true,  -- 显示坐标信息
    
    -- 日志设置
    enable_logging = false,
    log_file = "mpv_cut.log",
}

-- 读取用户配置
options.read_options(o, "slicing_optimized")

-- 工具函数：时间戳转换
function seconds_to_timestamp(seconds)
    if not seconds then return "00:00:00.000" end
    local hours = math.floor(seconds / 3600)
    local minutes = math.floor((seconds % 3600) / 60)
    local secs = seconds % 60
    return string.format("%02d:%02d:%06.3f", hours, minutes, secs)
end

-- 工具函数：生成安全文件名
function sanitize_filename(str)
    if not str then return "" end
    local replacements = {
        [":"] = "-", ["/"] = "_", ["\\"] = "_", 
        ["*"] = "", ["?"] = "", ["\""] = "", 
        ["<"] = "", [">"] = "", ["|"] = "", [" "] = "_"
    }
    for old, new in pairs(replacements) do
        str = str:gsub(old, new)
    end
    str = str:gsub("^%s+", ""):gsub("%s+$", "")
    return str
end

-- 工具函数：生成输出文件名
function generate_output_filename(start_time, end_time, is_cropped)
    local original = mp.get_property("filename")
    local basename = original:match("(.+)%..+$") or original
    
    basename = sanitize_filename(basename)
    
    -- ✅ 修复：时间戳格式要一致（HH-MM-SS-mmm）
    local start_str = seconds_to_timestamp(start_time)
        :gsub(":", "-")  -- 冒号变横线
        :gsub("%.", "-") -- 点变横线
    
    local end_str = seconds_to_timestamp(end_time)
        :gsub(":", "-")
        :gsub("%.", "-")
    
    -- 应用文件名模板
    local filename = o.filename_pattern
        :gsub("{basename}", basename)
        :gsub("{start}", start_str)
        :gsub("{end}", end_str)
        :gsub("{ext}", o.output_ext)
    
    -- 如果启用了裁剪，添加后缀
    if is_cropped and o.enable_crop and crop_area then
        filename = filename:gsub("%." .. o.output_ext .. "$", o.crop_suffix .. "." .. o.output_ext)
    end
    
    return filename
end

-- 清除裁剪区域
function clear_crop()
    crop_area = nil
    crop_mode = false
    crop_step = 0
    crop_points = {}
    crop_first_corner = nil
    
    -- 清除OSD绘制
    clear_rectangle()
    
    mp.osd_message("已清除裁剪区域", 2)
end

-- 显示当前裁剪状态
function show_crop_status()
    if crop_area then
        mp.osd_message(string.format("当前裁剪区域: %dx%d @(%d,%d)", 
            crop_area.w, crop_area.h, crop_area.x, crop_area.y), 3)
			local time = mp.get_property_number("time-pos")
    --mp.osd_message(string.format("当前: %s", seconds_to_timestamp(time)), 2)
    else
        mp.osd_message("未设置裁剪区域 (按'm'键启动框选模式)", 3)
    end
end

-- ✅ 修复：确保总是使用视频文件所在目录
function get_output_dir()
    local dir = o.target_dir
    
    if dir == "" or dir == "." then
        local path = mp.get_property("path")
        if path then
            local video_dir = utils.split_path(path)
            if video_dir then
                return video_dir
            end
        end
        return utils.getcwd()
    end
    
    if dir:sub(1, 1) == "~" then
        local home = os.getenv("HOME") or os.getenv("USERPROFILE") or ""
        dir = home .. dir:sub(2)
    end
    
    if dir and dir ~= "" then
        if not utils.file_info(dir) then
            if package.config:sub(1,1) == "\\" then -- Windows
                os.execute('mkdir "' .. dir:gsub('"', '\\"') .. '" 2>nul')
            else -- Unix/Linux
                os.execute('mkdir -p "' .. dir:gsub('"', '\\"') .. '" 2>/dev/null')
            end
        end
    end
    
    return dir or utils.getcwd()
end

-- ✅ 修复：构建FFmpeg命令（支持裁剪和非裁剪）
function build_ffmpeg_command(input_path, start_time, end_time, output_path)
    if crop_area and o.enable_crop then
        -- 使用裁剪命令（必须重新编码）
        local cmd = string.format(
            'ffmpeg -i "%s" -ss %s -to %s -vf "crop=%d:%d:%d:%d" -c:v %s -c:a %s -movflags +faststart "%s"',
            input_path,
            seconds_to_timestamp(start_time),
            seconds_to_timestamp(end_time),
            crop_area.w, crop_area.h, crop_area.x, crop_area.y,
            o.crop_video_codec,
            o.crop_audio_codec,
            output_path
        )
        return cmd
    else
        -- 使用普通剪切命令（可以复制流）
        local cmd = o.command_template
            :gsub("%s+", " ")
            :gsub("$input", input_path)
            :gsub("$start_time", seconds_to_timestamp(start_time))
            :gsub("$end_time", seconds_to_timestamp(end_time))
            :gsub("$output", output_path)
        
        return cmd:gsub("^%s*(.-)%s*$", "%1")
    end
end

-- ✅ 修复：核心剪切功能
function execute_cut(start_time, end_time)
    local input_path = mp.get_property("path")
    if not input_path then
        mp.osd_message("错误：无法获取文件路径", 3)
        msg.error("无法获取文件路径")
        return false
    end
    
    msg.info("=== 剪切调试开始 ===")
    msg.info("输入文件:", input_path)
    msg.info("时间范围:", seconds_to_timestamp(start_time), "->", seconds_to_timestamp(end_time))
    
    if crop_area then
        msg.info("裁剪区域:", string.format("%dx%d @(%d,%d)", 
            crop_area.w, crop_area.h, crop_area.x, crop_area.y))
    end
    
    local output_dir = get_output_dir()
    local filename = generate_output_filename(start_time, end_time, crop_area ~= nil)
    local output_path = utils.join_path(output_dir, filename)
    
    msg.info("输出目录:", output_dir)
    msg.info("输出文件名:", filename)
    msg.info("完整输出路径:", output_path)
    
    if not utils.file_info(input_path) then
        msg.error("输入文件不存在:", input_path)
        mp.osd_message("错误：输入文件不存在", 3)
        return false
    end
    
    local cmd = build_ffmpeg_command(input_path, start_time, end_time, output_path)
    msg.info("FFmpeg命令:", cmd)
    
    -- 检查输出目录是否存在
    if not utils.file_info(output_dir) then
        msg.info("创建输出目录:", output_dir)
        os.execute('mkdir -p "' .. output_dir .. '" 2>/dev/null')
    end
    
    msg.info("开始执行剪切...")
    
    -- 使用更好的命令执行方式
    local handle = io.popen(cmd .. " 2>&1", "r")
    local result = false
    local output = ""
    
    if handle then
        output = handle:read("*a")
        result = handle:close()
        msg.info("FFmpeg输出:", output)
    end
    
    if result then
        local file_info = utils.file_info(output_path)
        if file_info then
            local size_mb = file_info.size / (1024 * 1024)
            local action = crop_area and "裁剪剪切" or "剪切"
            msg.info(string.format("✓ %s成功！文件大小: %.2f MB", action, size_mb))
            msg.info("✓ 文件位置:", output_path)
            
            -- 清除矩形框
            clear_rectangle()
            
            mp.osd_message(string.format("✓ %s完成: %s (%.1fMB)", action, filename, size_mb), 5)
            log_cut_action(input_path, output_path, start_time, end_time, cmd)
            
            -- 可选：是否在剪切后清除裁剪区域
            -- crop_area = nil
        else
            msg.warn("命令成功但文件未找到")
            msg.warn("预期路径:", output_path)
            
            -- 尝试在目录中查找
            local files = utils.readdir(output_dir)
            if files then
                for _, file in ipairs(files) do
                    if file:find(filename:gsub("%.", "%%.")) then
                        msg.info("找到可能的文件:", file)
                    end
                end
            end
            
            mp.osd_message("⚠ 请手动检查输出文件", 3)
        end
    else
        msg.error("✗ FFmpeg执行失败")
        
        -- 显示错误信息
        if output and output ~= "" then
            msg.error("FFmpeg错误详情:", output)
            
            -- 常见错误提示
            if output:find("Invalid data found") then
                mp.osd_message("错误：视频格式不支持", 5)
            elseif output:find("Permission denied") then
                mp.osd_message("错误：无写入权限", 5)
            elseif output:find("libx264") or output:find("encoder") then
                mp.osd_message("错误：请安装编码器或检查配置", 5)
            else
                mp.osd_message("剪切失败，查看控制台", 5)
            end
        else
            mp.osd_message("剪切失败，未知错误", 5)
        end
    end
    
    msg.info("=== 剪切调试结束 ===")
    return result
end

-- 日志记录
function log_cut_action(input, output, start_time, end_time, command)
    if not o.enable_logging then return end
    
    local log_path = utils.join_path(get_output_dir(), o.log_file)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    
    local crop_info = ""
    if crop_area then
        crop_info = string.format(" 裁剪:%dx%d@(%d,%d)", 
            crop_area.w, crop_area.h, crop_area.x, crop_area.y)
    end
    
    local log_entry = string.format(
        "[%s] 输入:%s 输出:%s 时间:%s-%s%s\n命令:%s\n",
        timestamp, input, output, 
        seconds_to_timestamp(start_time), seconds_to_timestamp(end_time),
        crop_info, command
    )
    
    local file = io.open(log_path, "a")
    if file then
        file:write(log_entry)
        file:close()
    end
end

-- 主交互函数：标记/剪切
function toggle_cut_marker()
    local current_time = mp.get_property_number("time-pos")
    
    if not cut_pos then
        cut_pos = current_time
        local time_str = seconds_to_timestamp(current_time)
        
        -- 显示裁剪状态
        if crop_area then
            mp.osd_message(string.format("▶ 开始标记: %s (裁剪: %dx%d)", 
                time_str, crop_area.w, crop_area.h), 2)
        else
            mp.osd_message(string.format("▶ 开始标记: %s", time_str), 2)
        end
    else
        local start_time = cut_pos
        local end_time = current_time
        
        if start_time > end_time then
            start_time, end_time = end_time, start_time
            mp.osd_message("⚠ 已自动交换开始/结束时间", 1)
        end
        
        if end_time - start_time < 0.5 then
            mp.osd_message("错误: 片段太短 (<0.5秒)", 2)
            cut_pos = nil
            return
        end
        
        local start_str = seconds_to_timestamp(start_time)
        local end_str = seconds_to_timestamp(end_time)
        
        -- 显示操作信息
        if crop_area then
            mp.osd_message(string.format("✂ 裁剪剪切: %s 到 %s (%dx%d)", 
                start_str, end_str, crop_area.w, crop_area.h), 2)
        else
            mp.osd_message(string.format("✂ 剪切: %s 到 %s", start_str, end_str), 2)
        end
        
        execute_cut(start_time, end_time)
        
        cut_pos = nil
    end
end

-- 显示当前时间
function show_current_time()
    local time = mp.get_property_number("time-pos")
    mp.osd_message(string.format("当前: %s", seconds_to_timestamp(time)), 2)
end

-- 取消标记
function cancel_marker()
    cut_pos = nil
    mp.osd_message("已取消标记", 2)
end

-- ==================== 鼠标框选功能（从crop.lua移植） ====================

-- 屏幕坐标转换为视频归一化坐标
function screen_to_video_norm(point, dim)
    local ml, mt, mr, mb = dim.ml or 0, dim.mt or 0, dim.mr or 0, dim.mb or 0
    local video_width = dim.w - ml - mr
    local video_height = dim.h - mt - mb
    
    return {
        x = (point.x - ml) / video_width,
        y = (point.y - mt) / video_height
    }
end

-- 视频归一化坐标转换为屏幕坐标
function video_norm_to_screen(point, dim)
    local ml, mt, mr, mb = dim.ml or 0, dim.mt or 0, dim.mr or 0, dim.mb or 0
    local video_width = dim.w - ml - mr
    local video_height = dim.h - mt - mb
    
    return {
        x = math.floor(point.x * video_width + ml + 0.5),
        y = math.floor(point.y * video_height + mt + 0.5)
    }
end

-- 根据两个点计算矩形
function rect_from_two_points(p1, p2)
    local x1, x2 = p1.x, p2.x
    local y1, y2 = p1.y, p2.y
    
    -- 确保x1 < x2, y1 < y2
    if x1 > x2 then x1, x2 = x2, x1 end
    if y1 > y2 then y1, y2 = y2, y1 end
    
    return {
        x = x1,
        y = y1,
        w = x2 - x1,
        h = y2 - y1
    }
end

-- 绘制遮罩
function draw_shade(ass, unshaded, window)
    local c1, c2 = unshaded.top_left, unshaded.bottom_right
    local v = window
    
    ass:new_event()
    ass:pos(0, 0)
    ass:append("{\\an7}")
    ass:append("{\\bord0}")
    ass:append("{\\shad0}")
    ass:append("{\\c&H000000&}")
    ass:append("{\\1a&H" .. o.shade_opacity .. "}")
    ass:append("{\\2a&HFF}")
    ass:append("{\\3a&HFF}")
    ass:append("{\\4a&HFF}")
    
    ass:draw_start()
    ass:rect_cw(v.top_left.x, v.top_left.y, c1.x, c2.y) -- 左上
    ass:rect_cw(c1.x, v.top_left.y, v.bottom_right.x, c1.y) -- 右上
    ass:rect_cw(v.top_left.x, c2.y, c2.x, v.bottom_right.y) -- 左下
    ass:rect_cw(c2.x, c1.y, v.bottom_right.x, v.bottom_right.y) -- 右下
    ass:draw_stop()
end

-- 绘制边框
function draw_frame(ass, frame)
    local c1, c2 = frame.top_left, frame.bottom_right
    local b = o.frame_border_width
    
    ass:new_event()
    ass:pos(0, 0)
    ass:append("{\\an7}")
    ass:append("{\\bord0}")
    ass:append("{\\shad0}")
    ass:append("{\\c&H" .. o.frame_border_color .. "&}")
    ass:append("{\\1a&H00&}")
    ass:append("{\\2a&HFF&}")
    ass:append("{\\3a&HFF&}")
    ass:append("{\\4a&HFF&}")
    
    ass:draw_start()
    ass:rect_cw(c1.x, c1.y - b, c2.x + b, c1.y) -- 上边框
    ass:rect_cw(c2.x, c1.y, c2.x + b, c2.y + b) -- 右边框
    ass:rect_cw(c1.x - b, c2.y, c2.x, c2.y + b) -- 下边框
    ass:rect_cw(c1.x - b, c1.y - b, c1.x, c2.y) -- 左边框
    ass:draw_stop()
end

-- 绘制十字准线
function draw_crosshair(ass, center, window_size)
    ass:new_event()
    ass:pos(0, 0)
    ass:append("{\\an7}")
    ass:append("{\\bord0}")
    ass:append("{\\shad0}")
    ass:append("{\\c&HBBBBBB&}")
    ass:append("{\\1a&H00&}")
    ass:append("{\\2a&HFF&}")
    ass:append("{\\3a&HFF&}")
    ass:append("{\\4a&HFF&}")
    
    ass:draw_start()
    ass:rect_cw(center.x - 0.5, 0, center.x + 0.5, window_size.h) -- 垂直线
    ass:rect_cw(0, center.y - 0.5, window_size.w, center.y + 0.5) -- 水平线
    ass:draw_stop()
end

-- 绘制坐标文本
function draw_position_text(ass, text, position, window_size, offset)
    ass:new_event()
    local align = 1
    local ofx = 1
    local ofy = -1
    
    if position.x > window_size.w / 2 then
        align = align + 2
        ofx = -1
    end
    if position.y < window_size.h / 2 then
        align = align + 6
        ofy = 1
    end
    
    ass:append("{\\an"..align.."}")
    ass:append("{\\fs20}")
    ass:append("{\\bord1}")
    ass:pos(ofx*offset + position.x, ofy*offset + position.y)
    ass:append(text)
end

-- 绘制裁剪区域
function draw_crop_zone()
    if not crop_mode or not crop_first_corner then return end
    
    local dim = mp.get_property_native("osd-dimensions")
    if not dim then return end
    
    -- 获取当前鼠标位置
    local cursor = {x = crop_cursor.x, y = crop_cursor.y}
    
    -- 确保鼠标在视频区域内
    local ml, mt, mr, mb = dim.ml or 0, dim.mt or 0, dim.mr or 0, dim.mb or 0
    cursor.x = math.max(ml, math.min(dim.w - mr, cursor.x))
    cursor.y = math.max(mt, math.min(dim.h - mb, cursor.y))
    
    local ass = assdraw.ass_new()
    
    -- 如果已选择第一个点，绘制矩形
    if crop_first_corner then
        local frame = {}
        local p1 = video_norm_to_screen(crop_first_corner, dim)
        local p2 = cursor
        
        -- 确保矩形是正常的（左上到右下）
        local x1, x2 = p1.x, p2.x
        local y1, y2 = p1.y, p2.y
        if x1 > x2 then x1, x2 = x2, x1 end
        if y1 > y2 then y1, y2 = y2, y1 end
        
        frame.top_left = {x = x1, y = y1}
        frame.bottom_right = {x = x2, y = y2}
        
        -- 绘制遮罩
        if o.draw_shade then
            local window = {
                top_left = { x = 0, y = 0 },
                bottom_right = { x = dim.w, y = dim.h },
            }
            draw_shade(ass, frame, window)
        end
        
        -- 绘制边框
        if o.draw_frame then
            draw_frame(ass, frame)
        end
    end
    
    -- 绘制十字准线
    if o.draw_crosshair then
        draw_crosshair(ass, cursor, { w = dim.w, h = dim.h })
    end
    
    -- 绘制坐标信息
    if o.draw_text then
        local cursor_norm = screen_to_video_norm(cursor, dim)
        local vop = mp.get_property_native("video-out-params")
        
        if vop then
            local text = string.format("%d, %d", 
                math.floor(cursor_norm.x * vop.w + 0.5), 
                math.floor(cursor_norm.y * vop.h + 0.5))
            
            if crop_first_corner then
                local width = math.abs((cursor_norm.x - crop_first_corner.x) * vop.w)
                local height = math.abs((cursor_norm.y - crop_first_corner.y) * vop.h)
                text = string.format("%s (%dx%d)", text, math.floor(width), math.floor(height))
            end
            
            draw_position_text(ass, text, cursor, { w = dim.w, h = dim.h }, 10)
        end
    end
    
    mp.set_osd_ass(dim.w, dim.h, ass.text)
    crop_rect_drawn = true
end

-- 清除矩形绘制
function clear_rectangle()
    mp.set_osd_ass(0, 0, "")
    crop_rect_drawn = false
end

-- 鼠标移动处理
function handle_mouse_move()
    if not crop_mode then return end
    
    crop_cursor.x, crop_cursor.y = mp.get_mouse_pos()
    draw_crop_zone()
end

-- 鼠标点击处理
function handle_mouse_click()
    if not crop_mode then return end
    
    local dim = mp.get_property_native("osd-dimensions")
    if not dim then return end
    
    -- 获取当前鼠标位置并确保在视频区域内
    local cursor = {x = crop_cursor.x, y = crop_cursor.y}
    local ml, mt, mr, mb = dim.ml or 0, dim.mt or 0, dim.mr or 0, dim.mb or 0
    cursor.x = math.max(ml, math.min(dim.w - mr, cursor.x))
    cursor.y = math.max(mt, math.min(dim.h - mb, cursor.y))
    
    -- 转换为归一化坐标
    local cursor_norm = screen_to_video_norm(cursor, dim)
    
    if not crop_first_corner then
        -- 选择第一个点（左上角）
        crop_first_corner = cursor_norm
        mp.osd_message("已选择左上角，请点击选择右下角 (ESC取消)", 3)
    else
        -- 选择第二个点（右下角）
        local vop = mp.get_property_native("video-out-params")
        if not vop then
            mp.osd_message("错误：无法获取视频参数", 2)
            cancel_crop_selection()
            return
        end
        
        -- 计算矩形区域（像素坐标）
        local p1_norm = crop_first_corner
        local p2_norm = cursor_norm
        
        -- 确保矩形是正常的
        local x1, x2 = p1_norm.x, p2_norm.x
        local y1, y2 = p1_norm.y, p2_norm.y
        if x1 > x2 then x1, x2 = x2, x1 end
        if y1 > y2 then y1, y2 = y2, y1 end
        
        -- 转换为像素坐标
        local x = math.floor(x1 * vop.w + 0.5)
        local y = math.floor(y1 * vop.h + 0.5)
        local w = math.floor((x2 - x1) * vop.w + 0.5)
        local h = math.floor((y2 - y1) * vop.h + 0.5)
        
        -- 确保尺寸有效
        if w <= 0 or h <= 0 then
            mp.osd_message("错误：无效的裁剪区域", 2)
            cancel_crop_selection()
            return
        end
        
        -- 保存裁剪区域
        crop_area = {x = x, y = y, w = w, h = h}
        
        
        
        -- 完成框选
        cancel_crop_selection()
		-- 显示成功信息
        mp.osd_message(string.format("✓ 已设置裁剪区域: %dx%d @(%d,%d)", w, h, x, y), 5)
        
        -- 清除矩形绘制
        --clear_rectangle()
    end
end

-- 开始框选模式
function start_crop()
    if crop_mode then
        mp.osd_message("已在框选模式中", 2)
        return
    end
    
    local dim = mp.get_property_native("osd-dimensions")
    if not dim then
        mp.osd_message("错误：无法获取OSD尺寸", 2)
        return
    end
    
    -- 重置状态
    crop_mode = true
    crop_first_corner = nil
    crop_cursor.x, crop_cursor.y = mp.get_mouse_pos()
	
    -- 清除OSD绘制
    clear_rectangle()
    -- 绑定鼠标事件
    mouse_move_binding = mp.add_forced_key_binding("MOUSE_MOVE", "crop-mouse-move", handle_mouse_move)
    mouse_click_binding = mp.add_forced_key_binding("MOUSE_BTN0", "crop-mouse-click", handle_mouse_click)
    
    -- 显示提示信息
    mp.osd_message("框选模式: 点击选择左上角 (ESC取消)", 3)
    
    -- 注册重绘函数
    mp.register_idle(draw_crop_zone)
    
    msg.info("进入框选模式")
end

-- 取消框选
function cancel_crop_selection()
    crop_mode = false
    crop_first_corner = nil
    
    -- 移除鼠标绑定
    if mouse_move_binding then
        mp.remove_key_binding("crop-mouse-move")
        mouse_move_binding = nil
    end
    if mouse_click_binding then
        mp.remove_key_binding("crop-mouse-click")
        mouse_click_binding = nil
    end
    
    -- 清除OSD绘制
    --clear_rectangle()
    
    -- 取消注册重绘函数
    mp.unregister_idle(draw_crop_zone)
    
    mp.osd_message("已退出框选模式", 2)
    --msg.info("退出框选模式")
end

-- ESC键处理：取消框选
function handle_esc()
    if crop_mode then
        cancel_crop_selection()
        return true  -- 阻止默认ESC行为
    end
    return false
end

-- 键盘绑定
mp.add_key_binding("c", "cut_marker", toggle_cut_marker)
mp.add_key_binding("x", "cancel_cut", cancel_marker)
mp.add_key_binding("h", "show_crop_status", show_crop_status)
mp.add_key_binding("m", "start-crop", start_crop)
mp.add_key_binding("C", "clear_crop", clear_crop)  -- Shift+C 清除裁剪
mp.add_key_binding("ESC", "cancel-crop", cancel_crop_selection)  -- ESC 取消框选

-- 初始化消息
msg.info("增强版剪切脚本已加载 (支持鼠标框选裁剪)")
msg.info("使用方法:")
msg.info("  1. 按 'm' 键进入框选模式")
msg.info("  2. 按照提示，用鼠标点击选择左上角和右下角")
msg.info("  3. 自动设置裁剪区域并显示预览框")
msg.info("  4. 按 'c' 标记开始，再按 'c' 标记结束并剪切")
msg.info("  5. 按 'C' (Shift+c) 清除裁剪区域")
msg.info("  6. 按 'h' 显示当前剪切区域，按 'x' 取消标记")
msg.info("  7. 框选模式中按ESC取消选择")
msg.info("")
msg.info("注意: 裁剪区域会应用于后续的所有剪切操作")