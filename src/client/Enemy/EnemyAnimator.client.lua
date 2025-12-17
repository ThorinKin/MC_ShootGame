-- StarterPlayer/StarterPlayerScripts/Client/Enemy/EnemyAnimator.client.lua
local Players   = game:GetService("Players")
local Workspace = game:GetService("Workspace")
local EnemiesFolder = Workspace:WaitForChild("Enemies")

-- 工具：为一只敌人绑定本地动画逻辑
local function setupEnemy(enemy: Model)
	-- 防止重复绑定
	if enemy:GetAttribute("__ClientAnimatorSetup") then
		return
	end
	enemy:SetAttribute("__ClientAnimatorSetup", true)

	local humanoid = enemy:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end

	local animFolder = enemy:FindFirstChild("Animations")
	if not animFolder then
		warn("[EnemyAnimator] 敌人缺少 Animations 文件夹：", enemy.Name)
		return
	end

	local function loadAnim(name: string)
		local animObj = animFolder:FindFirstChild(name)
		if animObj and animObj:IsA("Animation") then
			local track = animator:LoadAnimation(animObj)
			return track
		else
			return nil
		end
	end

	local idleTrack   = loadAnim("Idle")
	local walkTrack   = loadAnim("Walk")
	-- 单体攻击动画优先用 SingleAttack 命名，兼容 Attack
	local attackTrack = loadAnim("SingleAttack") or loadAnim("Attack")

	if not idleTrack then
		warn("[EnemyAnimator] 敌人缺少 Idle 动画：", enemy.Name)
		return
	end

	idleTrack.Looped = true
	if walkTrack   then walkTrack.Looped   = true   end
	if attackTrack then attackTrack.Looped = false end

	local function stopAll(except)
		local list = { idleTrack, walkTrack, attackTrack }
		for _, t in ipairs(list) do
			if t and t ~= except then
				t:Stop(0.15)
			end
		end
	end

	local function playState(state: string?)
		state = state or "Idle"

		if state == "Idle" then
			if idleTrack and not idleTrack.IsPlaying then
				idleTrack:Play(0.15)
			end
			if walkTrack then walkTrack:Stop(0.2) end

		elseif state == "Walk" or state == "Return" then
			if walkTrack then
				if idleTrack and idleTrack.IsPlaying then
					idleTrack:Stop(0.15)
				end
				if not walkTrack.IsPlaying then
					walkTrack:Play(0.15)
				end
			end

		elseif state == "Attack" then
			-- 攻击动画本身改由 AttackTick Attribute 驱动
			-- 这里只负责停掉走路/待机，避免攻击时腿还在走路
			if idleTrack and idleTrack.IsPlaying then
				idleTrack:Stop(0.15)
			end
			if walkTrack and walkTrack.IsPlaying then
				walkTrack:Stop(0.15)
			end

		elseif state == "Dead" then
			stopAll(nil)
			-- 可做死亡动画-----！！
		else
			-- 其他未知状态：回 Idle
			if idleTrack and not idleTrack.IsPlaying then
				idleTrack:Play(0.1)
			end
		end
	end

	-- 初始化：先播 Idle
	idleTrack:Play(0.1)
	playState(enemy:GetAttribute("State"))

	-- 状态驱动（Idle / Walk / Attack / Return / Dead）
	enemy:GetAttributeChangedSignal("State"):Connect(function()
		playState(enemy:GetAttribute("State"))
	end)

	-- AttackTick 驱动攻击动画，每次服务器结算一次攻击就播一次
	if attackTrack then
		enemy:GetAttributeChangedSignal("AttackTick"):Connect(function()
			-- 每次 AttackTick 变化，重播一次攻击动画
			stopAll(attackTrack)
			attackTrack:Play(0.05)
		end)
	end

	humanoid.Died:Connect(function()
		stopAll(nil)
	end)
end

-- 启动时给已有敌人绑定
for _, enemy in ipairs(EnemiesFolder:GetChildren()) do
	if enemy:IsA("Model") then
		setupEnemy(enemy)
	end
end

-- 新刷出的敌人也绑定上
EnemiesFolder.ChildAdded:Connect(function(child)
	if child:IsA("Model") then
		setupEnemy(child)
	end
end)
