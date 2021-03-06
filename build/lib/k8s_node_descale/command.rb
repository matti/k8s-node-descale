require 'k8s_node_descale/version'

require 'base64'
require 'clamp'
require 'k8s-client'
require 'tempfile'
require 'time'
require 'tty-which'

require_relative 'kubectl'
require_relative 'scheduler'

module K8sNodeDescale
  class Command < Clamp::Command
    banner "Kubernetes Auto-scaling Group Descale - Drains after they reach their specified best-before date."

    option '--kubectl', 'PATH', 'specify path to kubectl (default: $PATH)', attribute_name: :kubectl_path do |kubectl|
      File.executable?(kubectl) || signal_usage_error("kubectl at #{kubectl} not found or unusable")
      kubectl
    end

    option '--kube-config', 'PATH', 'Kubernetes config path', environment_variable: 'KUBECONFIG' do |kube_config|
      ENV['KUBECONFIG'] = kube_config
    end

    option '--max-age', 'DURATION', 'maximum age of server before draining', default: '3d', environment_variable: 'MAX_AGE'
    option '--max-nodes', 'COUNT', 'drain maximum of COUNT nodes per cycle', default: 1, environment_variable: 'MAX_NODES_COUNT' do |count|
      Integer(count)
    end

    option '--check-period', 'SCHEDULE', 'run periodically, example: --check-period 1h', environment_variable: 'CHECK_PERIOD', attribute_name: :scheduler do |period|
      unless period.match?(/^\d+[hmsdy]$/)
        signal_usage_error "invalid format for --check-period. use <number><unit>, example: 30s, 1h, 3d"
      end
      Scheduler.new(period)
    end

    option '--dry-run', :flag, "perform a dry-run, doesn't drain any instances.", default: false, environment_variable: 'DRY_RUN'
    option ['-v', '--version'], :flag, "Display k8s-node-descale version" do
      puts "k8s-node-descale version #{K8sNodeDescale::VERSION}"
      exit 0
    end

    execute do
      Log.info "Running Kubernetes Node Descale version #{K8sNodeDescale::VERSION}"
      Log.debug { "Validating kube credentials" }
      begin
        kubectl
        kube_client.api('v1').resource('nodes').list
      rescue => ex
        signal_usage_error 'failed to connect to Kubernetes API, see --help for connection options (%s)' % ex.message
      end

      scheduler.run do
        terminated_count = 0
        Log.info "Requesting node information .."

        nodes = kube_client.api('v1').resource('nodes').list.sort_by do |node|
          Time.xmlschema(node.metadata.creationTimestamp)
        end

        nodes.delete_if do |node|
          if node.metadata.labels['node-role.kubernetes.io/control-plane'] == 'true'
            true
          elsif node.metadata.labels['node-role.kubernetes.io/master'] == 'true'
            true
          else
            false
          end
        end

        draining_nodes = []
        nodes.each do |node|
          node.spec&.taints&.each do |taint|
            if taint.key == "node.kubernetes.io/unschedulable" && taint.effect == "NoSchedule"
              draining_nodes << node
            end
          end
        end

        if draining_nodes.size >= max_nodes
          pp [:too_many_nodes_draining, draining_nodes.size]
          next
        end

        nodes.each do |node|
          name = node.metadata&.name
          Log.debug { "Node name %p" % name }
          next if name.nil?

          age_secs = (Time.now - Time.xmlschema(node.metadata.creationTimestamp)).to_i
          Log.debug { "Node %s age: %d seconds" % [name, age_secs] }

          if age_secs > max_age_seconds
            Log.warn "!!! Node #{name} max-age expired, terminating !!!"

            if dry_run?
              Log.info "[dry-run] Would drain node %s" % name
            else
              Log.info "Draining node %s .." % name
            end
            drain_node(name)
            Log.debug { "Done draining node %s" % name }

            terminated_count += 1
            if terminated_count >= max_nodes
              Log.info "Reached termination --max-nodes count, breaking cycle."
              break
            end
          else
            Log.debug { "Node %s has not reached best-before" % name }
          end
        end

        Log.debug { "Round completed .." }
      rescue Exception => ex
        Log.debug { "Execption #{ex} #{ex.message}" }
      end
      Log.info "Done"
    end

    def default_kubectl_path
      TTY::Which.which('kubectl') || signal_usage_error('kubectl not found in PATH, use --kubectl <path> to set location manually')
    end

    def kubectl
      @kubectl ||= Kubectl.new(kubectl_path)
    end

    def drain_node(name)
      kubectl.drain(name, dry_run: dry_run?)
    end

    def default_scheduler
      Scheduler.new
    end

    def max_age_seconds
      @max_age_seconds ||= to_sec(max_age)
    end

    def to_sec(duration_string)
      num = duration_string[0..-2].to_i
      case duration_string[-1]
      when 's' then num
      when 'm' then num * 60
      when 'h' then num * 60 * 60
      when 'd' then num * 60 * 60 * 24
      when 'w' then num * 60 * 60 * 24 * 7
      when 'M' then num * 60 * 60 * 24 * 30
      when 'Y' then num * 60 * 60 * 24 * 365
      else
        signal_usage_error 'invalid --max-age format'
      end
    end

    private

    # @return [K8s::Client]
    def kube_client
      return @kube_client if @kube_client

      if kube_config
        @kube_client = K8s::Client.config(K8s::Config.load_file(kube_config))
      else
        @kube_client = K8s::Client.in_cluster_config
      end

      @kube_client
    end
  end
end
